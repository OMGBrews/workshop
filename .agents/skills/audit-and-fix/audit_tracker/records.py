"""JSON source-of-truth for audit records.

Each audit type has its own file at ``<repo>/docs/work/audits/records/<type>.json``
holding the per-path audit history of the control repository. A declared
subject repository's records live one level down, at
``records/<repository>/<type>.json``, with paths relative to that subject's
root. Both are owned and committed by the control repository.
The SQLite database is a derivable cache — :func:`load_into_db`
repopulates it from these files on every CLI invocation, and
:func:`write_record` writes through whenever ``done()`` records a new
audit. Storing audits as text per audit type makes concurrent branches
merge cleanly: branches that audited different paths produce
non-overlapping diffs, and same-path conflicts surface as normal text
conflicts that a human resolves (the correct semantic — both branches
audited the same path, and someone must decide which audit "wins").

File format::

    {
      "audits": {
        "app/features/foo.py": {
          "last_audited_at": "2026-05-10T12:34:56+00:00",
          "last_audit_commit": "abc123def456"
        },
        "evals/some/path.py": {
          "last_audited_at": "2026-05-09T08:00:00+00:00",
          "last_audit_commit": "789xyz",
          "notes": "optional free-form note"
        }
      }
    }

Files are written with ``sort_keys`` and a fixed indent so re-recording an
audit produces minimal, deterministic, text-mergeable diffs.

Refresh state is *not* a record: it lives beside the SQLite cache under the
repo's git dir (see :mod:`audit_tracker.db`), regenerated freely and never
committed — concurrent workers once conflicted on it when it was a tracked
sibling of the records.
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import tempfile
from contextlib import contextmanager
from fcntl import LOCK_EX, LOCK_UN, flock
from pathlib import Path
from collections.abc import Iterable, Iterator
from typing import TypedDict

from . import git_utils
from .config import SELF_REPOSITORY
from .db import cache_dir

RECORDS_SUBDIR = "docs/work/audits/records"


class _AuditEntry(TypedDict, total=False):
    """Single audit record as stored in JSON."""

    last_audited_at: str
    last_audit_commit: str | None
    notes: str | None


class _RecordsFile(TypedDict, total=False):
    """Top-level shape of a per-audit-type records file."""

    pick_counter: int
    audits: dict[str, _AuditEntry]


class RefreshState(TypedDict, total=False):
    """Persisted record of one repository's most recent ``refresh()`` run.

    The control repository's state sits at the top level of
    ``refresh-state.json``, exactly where single-repository trackers have
    always kept it. Each declared subject's state sits under
    ``repositories.<name>`` with the same fields, so refreshing one
    repository never marks another fresh.
    """

    last_refreshed_at: str
    last_refresh_commit: str | None
    config_digest: str | None
    index_fingerprint: str | None

_STATE_FIELDS = ("last_refreshed_at", "last_refresh_commit", "config_digest", "index_fingerprint")


def default_records_dir(repo: Path | None = None) -> Path:
    """The consumer-repo records directory: ``<repo>/docs/work/audits/records``."""
    base = repo if repo is not None else git_utils.repo_root()
    return base / RECORDS_SUBDIR


def records_path(
    audit_type: str,
    records_dir: Path | None = None,
    repository: str = SELF_REPOSITORY,
) -> Path:
    """Resolve the JSON file path for ``audit_type`` in ``repository``.

    The base directory defaults to ``<repo>/docs/work/audits/records`` and
    can be overridden for tests via ``records_dir``. A subject repository's
    file sits in a folder named after it; repository names are validated by
    the config parser, so the folder can never escape ``records/``.
    """
    base = records_dir or default_records_dir()
    if repository != SELF_REPOSITORY:
        base = base / repository
    return base / f"{audit_type}.json"


def _read_records_file(path: Path) -> _RecordsFile:
    """Load one records file. Missing files are treated as empty."""
    if not path.exists():
        return {"audits": {}}
    with path.open(encoding="utf-8") as fh:
        raw = json.load(fh)
    if raw is None:
        return {"audits": {}}
    if not isinstance(raw, dict):
        raise ValueError(f"{path}: expected a JSON object at the top level, got {type(raw).__name__}")
    pick_counter = raw.get("pick_counter")
    if pick_counter is not None and not isinstance(pick_counter, int):
        raise ValueError(f"{path}: pick_counter must be an int, got {type(pick_counter).__name__}")
    audits = raw.get("audits") or {}
    if not isinstance(audits, dict):
        raise ValueError(f"{path}: audits must be an object, got {type(audits).__name__}")
    parsed: _RecordsFile = {"audits": audits}
    if pick_counter is not None:
        parsed["pick_counter"] = pick_counter
    return parsed


def _write_records_file(path: Path, data: _RecordsFile) -> None:
    """Atomically serialize a records file with deterministic ordering."""
    path.parent.mkdir(parents=True, exist_ok=True)
    audits = data.get("audits") or {}
    payload: dict[str, object] = {"audits": {k: dict(audits[k]) for k in sorted(audits)}}
    # Read legacy counters for compatibility, but never create or advance one.
    # Existing files retain their value until a deliberate migration removes
    # it, avoiding a noisy fleet-wide rewrite on the next audit.
    if "pick_counter" in data:
        payload["pick_counter"] = data["pick_counter"]
    text = json.dumps(payload, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


@contextmanager
def _records_lock(audit_type: str, repository: str = SELF_REPOSITORY) -> Iterator[None]:
    """Serialize read-modify-write cycles for one records file in this clone."""
    lock_dir = cache_dir()
    if repository != SELF_REPOSITORY:
        # A folder per subject, mirroring records/<repository>/, so no
        # spelling of name plus type can collide with another file's lock.
        lock_dir = lock_dir / "repositories" / repository
    lock_dir.mkdir(parents=True, exist_ok=True)
    safe_name = audit_type.replace("/", "_")
    with (lock_dir / f"records-{safe_name}.lock").open("a+") as handle:
        flock(handle.fileno(), LOCK_EX)
        try:
            yield
        finally:
            flock(handle.fileno(), LOCK_UN)


def load_into_db(
    conn: sqlite3.Connection,
    records_dir: Path | None = None,
    repositories: Iterable[str] = (SELF_REPOSITORY,),
) -> None:
    """Replace the DB's ``audits`` and ``audit_type_state`` rows for
    ``repositories`` with the JSON-resident records.

    ``paths`` and ``path_audit_applicability`` are untouched — those
    tables are reconciled by ``refresh.refresh`` against the git
    tree, not loaded from JSON. Callers that want to record an audit
    on a path the DB doesn't know about must run ``refresh`` first.

    Only the named repositories are reloaded, so a command scoped to one
    repository neither needs nor disturbs another's (possibly unrefreshed)
    rows.
    """
    base = records_dir or default_records_dir()
    base.mkdir(parents=True, exist_ok=True)

    with conn:
        for repository in repositories:
            _load_repository(conn, base, repository)


def _load_repository(conn: sqlite3.Connection, base: Path, repository: str) -> None:
    conn.execute("DELETE FROM audits WHERE repository = ?", (repository,))
    conn.execute("DELETE FROM audit_type_state WHERE repository = ?", (repository,))
    folder = base if repository == SELF_REPOSITORY else base / repository
    if not folder.is_dir():
        return
    known_paths = {
        row[0]
        for row in conn.execute("SELECT path FROM paths WHERE repository = ?", (repository,))
    }
    label = "" if repository == SELF_REPOSITORY else f"{repository}/"
    for json_path in sorted(folder.glob("*.json")):
        # Leading-underscore files hold tracker meta state, not
        # audit-type records — skip them (same rule as the YAML days,
        # stepped to the new extension).
        if json_path.name.startswith("_"):
            continue
        audit_type = json_path.stem
        data = _read_records_file(json_path)
        audits = data.get("audits") or {}
        rows: list[tuple[str, str, str, str | None, str | None, str | None]] = []
        orphans: list[str] = []
        for path, entry in audits.items():
            # Records can outlive a path that has been deleted from git
            # (refresh prunes paths but not records). Skip orphans so
            # the audits FK doesn't blow up; the JSON entry stays put
            # until a human removes it.
            if path not in known_paths:
                orphans.append(path)
                continue
            rows.append(
                (
                    repository,
                    path,
                    audit_type,
                    entry.get("last_audited_at"),
                    entry.get("last_audit_commit"),
                    entry.get("notes"),
                )
            )
        if orphans:
            preview = ", ".join(orphans[:3]) + (", ..." if len(orphans) > 3 else "")
            print(
                f"audit_tracker: skipping {len(orphans)} orphan record(s) in "
                f"{label}{json_path.name} (path no longer in git): {preview}",
                file=sys.stderr,
            )
        conn.executemany(
            """
            INSERT INTO audits
              (repository, path, audit_type, last_audited_at, last_audit_commit, notes)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        # Keep the legacy cache row readable for older callers. New code
        # does not use or mutate this merge-prone global counter.
        conn.execute(
            "INSERT INTO audit_type_state (repository, audit_type, pick_counter) "
            "VALUES (?, ?, ?)",
            (repository, audit_type, data.get("pick_counter", 0)),
        )


def _refresh_state_path(cache: Path | None = None) -> Path:
    return (cache if cache is not None else cache_dir()) / "refresh-state.json"


def _read_state_file(cache: Path | None) -> dict[str, object] | None:
    path = _refresh_state_path(cache)
    if not path.exists():
        return None
    try:
        with path.open(encoding="utf-8") as fh:
            raw = json.load(fh)
    except json.JSONDecodeError:
        # Derived state: an unreadable file only means "refresh again".
        return None
    return raw if isinstance(raw, dict) else None


def _parse_state(raw: object) -> RefreshState | None:
    if not isinstance(raw, dict):
        return None
    last_at = raw.get("last_refreshed_at")
    if not isinstance(last_at, str):
        return None
    commit = raw.get("last_refresh_commit")
    if commit is not None and not isinstance(commit, str):
        commit = None
    config_digest = raw.get("config_digest")
    if config_digest is not None and not isinstance(config_digest, str):
        config_digest = None
    index = raw.get("index_fingerprint")
    if index is not None and not isinstance(index, str):
        index = None
    state: RefreshState = {
        "last_refreshed_at": last_at,
        "last_refresh_commit": commit,
    }
    if config_digest is not None:
        state["config_digest"] = config_digest
    if index is not None:
        state["index_fingerprint"] = index
    return state


def read_refresh_state(
    cache: Path | None = None, repository: str = SELF_REPOSITORY
) -> RefreshState | None:
    """Return ``repository``'s most recent refresh timestamp + commit, or
    ``None`` when no refresh has been recorded for it yet (or the file is
    unreadable).
    """
    raw = _read_state_file(cache)
    if raw is None:
        return None
    if repository == SELF_REPOSITORY:
        return _parse_state(raw)
    subjects = raw.get("repositories")
    if not isinstance(subjects, dict):
        return None
    return _parse_state(subjects.get(repository))


def write_refresh_state(
    *,
    last_refreshed_at: str,
    last_refresh_commit: str | None,
    config_digest: str | None = None,
    index_fingerprint: str | None = None,
    cache: Path | None = None,
    repository: str = SELF_REPOSITORY,
) -> None:
    """Persist one repository's refresh state so the question "when was the
    tracker last reconciled?" survives across SQLite-cache rebuilds.

    Other repositories' entries in the same file are preserved.
    """
    path = _refresh_state_path(cache)
    path.parent.mkdir(parents=True, exist_ok=True)
    entry: dict[str, object] = {
        "last_refreshed_at": last_refreshed_at,
        "last_refresh_commit": last_refresh_commit,
        "config_digest": config_digest,
        "index_fingerprint": index_fingerprint,
    }
    existing = _read_state_file(cache) or {}
    if repository == SELF_REPOSITORY:
        payload: dict[str, object] = dict(entry)
        if isinstance(existing.get("repositories"), dict):
            payload["repositories"] = existing["repositories"]
    else:
        payload = {key: existing[key] for key in _STATE_FIELDS if key in existing}
        subjects = existing.get("repositories")
        subjects = dict(subjects) if isinstance(subjects, dict) else {}
        subjects[repository] = entry
        payload["repositories"] = subjects
    text = json.dumps(payload, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)


def write_record(
    audit_type: str,
    path: str,
    *,
    last_audited_at: str,
    last_audit_commit: str | None,
    notes: str | None,
    pick_counter: int | None = None,
    records_dir: Path | None = None,
    repository: str = SELF_REPOSITORY,
) -> None:
    """Upsert one audit record into ``repository``'s per-type JSON file.

    ``notes`` is preserved when ``None`` is passed and a prior note
    exists, matching the SQLite ``done()`` semantic. Pass an empty
    string to clear the note. ``pick_counter`` is accepted but ignored for
    compatibility with callers from before rotation state became local-only.
    """
    file_path = records_path(audit_type, records_dir, repository)
    with _records_lock(audit_type, repository):
        # The lock covers the whole read-modify-replace cycle. Atomic replace
        # protects readers; the lock prevents two writers from both reading
        # the same predecessor and dropping one another's path updates.
        data = _read_records_file(file_path)
        audits = data.get("audits") or {}
        existing = audits.get(path, {})
        new_entry: _AuditEntry = {
            "last_audited_at": last_audited_at,
            "last_audit_commit": last_audit_commit,
        }
        if notes is None:
            prior = existing.get("notes")
            if prior is not None:
                new_entry["notes"] = prior
        elif notes != "":
            new_entry["notes"] = notes
        audits[path] = new_entry
        data["audits"] = audits
        _write_records_file(file_path, data)
