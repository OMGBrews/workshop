"""JSON source-of-truth for audit records.

Each audit type has its own file at ``<repo>/docs/work/audits/records/<type>.json``
holding the per-path audit history and the round-robin pick counter.
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
      "pick_counter": 17,
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
import sqlite3
import sys
from pathlib import Path
from typing import TypedDict

from . import git_utils
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


class RefreshState(TypedDict):
    """Persisted record of the most recent ``refresh()`` run."""

    last_refreshed_at: str
    last_refresh_commit: str | None


def default_records_dir(repo: Path | None = None) -> Path:
    """The consumer-repo records directory: ``<repo>/docs/work/audits/records``."""
    base = repo if repo is not None else git_utils.repo_root()
    return base / RECORDS_SUBDIR


def records_path(audit_type: str, records_dir: Path | None = None) -> Path:
    """Resolve the JSON file path for ``audit_type``.

    The base directory defaults to ``<repo>/docs/work/audits/records`` and
    can be overridden for tests via ``records_dir``.
    """
    base = records_dir or default_records_dir()
    return base / f"{audit_type}.json"


def _read_records_file(path: Path) -> _RecordsFile:
    """Load one records file. Missing files are treated as empty."""
    if not path.exists():
        return {"pick_counter": 0, "audits": {}}
    with path.open(encoding="utf-8") as fh:
        raw = json.load(fh)
    if raw is None:
        return {"pick_counter": 0, "audits": {}}
    if not isinstance(raw, dict):
        raise ValueError(f"{path}: expected a JSON object at the top level, got {type(raw).__name__}")
    pick_counter = raw.get("pick_counter", 0)
    if not isinstance(pick_counter, int):
        raise ValueError(f"{path}: pick_counter must be an int, got {type(pick_counter).__name__}")
    audits = raw.get("audits") or {}
    if not isinstance(audits, dict):
        raise ValueError(f"{path}: audits must be an object, got {type(audits).__name__}")
    return {"pick_counter": pick_counter, "audits": audits}


def _write_records_file(path: Path, data: _RecordsFile) -> None:
    """Serialize a records file with sorted keys for deterministic diffs."""
    path.parent.mkdir(parents=True, exist_ok=True)
    audits = data.get("audits") or {}
    payload: dict[str, object] = {
        "pick_counter": data.get("pick_counter", 0),
        "audits": {k: dict(audits[k]) for k in sorted(audits)},
    }
    text = json.dumps(payload, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    path.write_text(text, encoding="utf-8")


def load_into_db(conn: sqlite3.Connection, records_dir: Path | None = None) -> None:
    """Replace the DB's ``audits`` and ``audit_type_state`` rows with the
    JSON-resident records.

    ``paths`` and ``path_audit_applicability`` are untouched — those
    tables are reconciled by ``refresh.refresh`` against the git
    tree, not loaded from JSON. Callers that want to record an audit
    on a path the DB doesn't know about must run ``refresh`` first.
    """
    base = records_dir or default_records_dir()
    base.mkdir(parents=True, exist_ok=True)

    with conn:
        conn.execute("DELETE FROM audits")
        conn.execute("DELETE FROM audit_type_state")
        known_paths = {row[0] for row in conn.execute("SELECT path FROM paths")}
        for json_path in sorted(base.glob("*.json")):
            # Leading-underscore files hold tracker meta state, not
            # audit-type records — skip them (same rule as the YAML days,
            # stepped to the new extension).
            if json_path.name.startswith("_"):
                continue
            audit_type = json_path.stem
            data = _read_records_file(json_path)
            audits = data.get("audits") or {}
            rows: list[tuple[str, str, str | None, str | None, str | None]] = []
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
                    f"{json_path.name} (path no longer in git): {preview}",
                    file=sys.stderr,
                )
            conn.executemany(
                """
                INSERT INTO audits (path, audit_type, last_audited_at, last_audit_commit, notes)
                VALUES (?, ?, ?, ?, ?)
                """,
                rows,
            )
            conn.execute(
                "INSERT INTO audit_type_state (audit_type, pick_counter) VALUES (?, ?)",
                (audit_type, data.get("pick_counter", 0)),
            )


def _refresh_state_path(cache: Path | None = None) -> Path:
    return (cache if cache is not None else cache_dir()) / "refresh-state.json"


def read_refresh_state(cache: Path | None = None) -> RefreshState | None:
    """Return the most recent refresh's timestamp + commit, or ``None``
    when no refresh has been recorded yet (or the file is unreadable).
    """
    path = _refresh_state_path(cache)
    if not path.exists():
        return None
    with path.open(encoding="utf-8") as fh:
        raw = json.load(fh)
    if not isinstance(raw, dict):
        return None
    last_at = raw.get("last_refreshed_at")
    if not isinstance(last_at, str):
        return None
    commit = raw.get("last_refresh_commit")
    if commit is not None and not isinstance(commit, str):
        commit = None
    return {"last_refreshed_at": last_at, "last_refresh_commit": commit}


def write_refresh_state(
    *,
    last_refreshed_at: str,
    last_refresh_commit: str | None,
    cache: Path | None = None,
) -> None:
    """Persist refresh state so the question "when was the tracker last
    reconciled?" survives across SQLite-cache rebuilds.
    """
    path = _refresh_state_path(cache)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload: dict[str, object] = {
        "last_refreshed_at": last_refreshed_at,
        "last_refresh_commit": last_refresh_commit,
    }
    text = json.dumps(payload, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    path.write_text(text, encoding="utf-8")


def write_record(
    audit_type: str,
    path: str,
    *,
    last_audited_at: str,
    last_audit_commit: str | None,
    notes: str | None,
    pick_counter: int,
    records_dir: Path | None = None,
) -> None:
    """Upsert one audit record into the per-type JSON file.

    ``notes`` is preserved when ``None`` is passed and a prior note
    exists, matching the SQLite ``done()`` semantic. Pass an empty
    string to clear the note.
    """
    file_path = records_path(audit_type, records_dir)
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
    data["pick_counter"] = pick_counter
    _write_records_file(file_path, data)
