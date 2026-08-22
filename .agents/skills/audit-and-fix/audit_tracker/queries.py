"""Audit tracker queries: next, done, status, list-types.

All queries read/write through a live SQLite connection. Staleness is
computed against git history (via ``git_utils``) so the DB does not need
to cache per-path mtimes.
"""

import hashlib
import sqlite3
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from . import git_utils, records
from .config import PathKind

AuditReason = Literal["never-audited", "stale", "clean"]


@dataclass(frozen=True)
class NextCandidate:
    """One row returned by :func:`next_paths`."""

    path: str
    kind: str
    last_audited_at: str | None
    commits_since_audit: int
    reason: AuditReason


@dataclass(frozen=True)
class AuditTypeStatus:
    """Summary counts for one audit type: total applicable vs audited, never, stale."""

    audit_type: str
    total: int
    audited: int
    never: int
    stale: int


def normalize_path_prefix(raw: str) -> str:
    """Normalize a user-supplied path prefix for subtree filtering.

    Strips whitespace, leading ``./``, trailing slashes. Rejects absolute
    paths and any prefix containing ``.``, ``..``, or empty segments so
    callers cannot escape the repo root or express ambiguous traversal.
    """
    cleaned = raw.strip()
    if not cleaned:
        raise ValueError("path prefix must not be empty")
    if cleaned.startswith("/"):
        raise ValueError(f"path prefix must be repo-relative, not absolute: {raw!r}")
    while cleaned.startswith("./"):
        cleaned = cleaned[2:]
    cleaned = cleaned.rstrip("/")
    if not cleaned or cleaned == ".":
        raise ValueError("path prefix must not be empty or '.'")
    parts = cleaned.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"path prefix must not contain '.', '..', or empty segments: {raw!r}")
    return cleaned


def _escape_like(value: str) -> str:
    """Escape LIKE wildcards so ``_`` and ``%`` match literally."""
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _applicable_rows(
    conn: sqlite3.Connection,
    audit_type: str,
    kind: PathKind | None = None,
    path_prefix: str | None = None,
) -> list[sqlite3.Row]:
    """All applicable paths joined with their latest audit (if any).

    If ``kind`` is given, filter to only files or only directories.
    If ``path_prefix`` is given, include only the path itself and its
    descendants (``prefix`` or ``prefix/...``).
    """
    sql = """
        SELECT
          p.path            AS path,
          p.kind            AS kind,
          a.last_audited_at AS last_audited_at,
          a.last_audit_commit AS last_audit_commit
        FROM path_audit_applicability ap
        JOIN paths p ON p.path = ap.path
        LEFT JOIN audits a
               ON a.path = ap.path AND a.audit_type = ap.audit_type
        WHERE ap.audit_type = ?
    """
    params: list[str | PathKind] = [audit_type]
    if kind is not None:
        sql += " AND p.kind = ?"
        params.append(kind)
    if path_prefix is not None:
        sql += " AND (p.path = ? OR p.path LIKE ? ESCAPE '\\')"
        params.extend([path_prefix, _escape_like(path_prefix) + "/%"])
    return list(conn.execute(sql, tuple(params)))


def _stable_hash(s: str) -> str:
    """Deterministic pseudo-random key for ``s`` — uniform over the path space."""
    return hashlib.sha256(s.encode()).hexdigest()


def _round_robin_by_parent_dir(
    candidates: list[NextCandidate], start_offset: int = 0
) -> list[NextCandidate]:
    """Interleave candidates so consecutive picks come from different parent dirs.

    Ordering is deterministic (same path set + same ``start_offset`` → same
    output) but uniform: both the rotation of directories and the order of
    files within a directory use ``sha256(path)`` as the sort key, avoiding
    alphabetical clustering (e.g. ``__init__.py`` always landing first
    because ``_`` sorts before letters).

    ``start_offset`` rotates the hash-sorted directory list by that many
    positions before draining. Callers pass the per-audit-type pick counter
    so that back-to-back ``next_paths(limit=1)`` calls land in different
    parent dirs across sessions, not just within one call.
    """
    grouped: dict[str, list[NextCandidate]] = defaultdict(list)
    for candidate in candidates:
        grouped[str(Path(candidate.path).parent)].append(candidate)
    for group in grouped.values():
        group.sort(key=lambda c: _stable_hash(c.path))

    queues: dict[str, deque[NextCandidate]] = {
        directory: deque(group) for directory, group in grouped.items()
    }
    dirs_sorted = sorted(queues.keys(), key=_stable_hash)
    if dirs_sorted:
        offset = start_offset % len(dirs_sorted)
        dirs_rotated = dirs_sorted[offset:] + dirs_sorted[:offset]
    else:
        dirs_rotated = dirs_sorted
    rotation: deque[str] = deque(dirs_rotated)
    interleaved: list[NextCandidate] = []
    while rotation:
        directory = rotation.popleft()
        interleaved.append(queues[directory].popleft())
        if queues[directory]:
            rotation.append(directory)
    return interleaved


def _pick_counter(conn: sqlite3.Connection, audit_type: str) -> int:
    """Read the rotation counter for ``audit_type`` (0 if never set)."""
    row = conn.execute(
        "SELECT pick_counter FROM audit_type_state WHERE audit_type = ?",
        (audit_type,),
    ).fetchone()
    return int(row["pick_counter"]) if row is not None else 0


_UNKNOWN_COMMIT = -1
"""Sentinel stored in the ``commits_since`` cache when the recorded SHA is
no longer present in the repo. Classified as stale so the path re-surfaces
for re-audit — we cannot prove the prior audit is current."""


def _classify_row(
    row: sqlite3.Row,
    commits_cache: dict[tuple[str, str], int],
) -> tuple[AuditReason, NextCandidate]:
    """Bucket one applicable row as never-audited, stale, or clean.

    A row is **stale** when its recorded commit is NULL, missing from the
    repo (rebased/GC'd), or strictly older than HEAD on the given path —
    in every case we can't prove the audit is current. ``commits_cache``
    memoises ``(sha, path) -> commits_since`` so we never fork ``git``
    twice for the same pair within one query.
    """
    last_at = row["last_audited_at"]
    last_sha = row["last_audit_commit"]
    path = row["path"]
    kind = row["kind"]

    if last_at is None:
        return "never-audited", NextCandidate(
            path=path,
            kind=kind,
            last_audited_at=None,
            commits_since_audit=0,
            reason="never-audited",
        )
    if not last_sha:
        return "stale", NextCandidate(
            path=path,
            kind=kind,
            last_audited_at=last_at,
            commits_since_audit=0,
            reason="stale",
        )

    cache_key = (last_sha, path)
    if cache_key not in commits_cache:
        try:
            commits_cache[cache_key] = git_utils.commits_since(last_sha, path)
        except git_utils.UnknownCommitError:
            commits_cache[cache_key] = _UNKNOWN_COMMIT
    commits = commits_cache[cache_key]

    if commits == _UNKNOWN_COMMIT or commits > 0:
        return "stale", NextCandidate(
            path=path,
            kind=kind,
            last_audited_at=last_at,
            commits_since_audit=max(commits, 0),
            reason="stale",
        )
    return "clean", NextCandidate(
        path=path,
        kind=kind,
        last_audited_at=last_at,
        commits_since_audit=0,
        reason="clean",
    )


def next_paths(
    conn: sqlite3.Connection,
    audit_type: str,
    *,
    limit: int = 1,
    only_never: bool = False,
    only_stale: bool = False,
    kind: PathKind | None = None,
    path_prefix: str | None = None,
) -> list[NextCandidate]:
    """Return the next path(s) to audit for ``audit_type``.

    Default ordering:
      1. Never audited          (round-robin by parent directory)
      2. Stale — changed since  (most commits since audit first)
      3. Oldest ``last_audited_at``

    Bucket 1 is interleaved so consecutive picks land in different parent
    directories — the first N picks cover min(N, num_dirs) distinct
    directories. This maximises coverage when audit effort is limited,
    since auditing one file tends to incidentally improve its neighbours.

    Filters: ``only_never`` returns only bucket 1; ``only_stale`` returns
    only bucket 2; ``kind`` restricts to files or directories only;
    ``path_prefix`` restricts to the path itself and its descendants (the
    caller is responsible for normalizing via :func:`normalize_path_prefix`).

    ``limit`` truncates the result; ``limit=0`` returns an empty list and a
    negative ``limit`` returns every candidate.
    """
    rows = _applicable_rows(conn, audit_type, kind=kind, path_prefix=path_prefix)
    commits_cache: dict[tuple[str, str], int] = {}

    never: list[NextCandidate] = []
    stale: list[NextCandidate] = []
    audited_clean: list[NextCandidate] = []
    buckets: dict[AuditReason, list[NextCandidate]] = {
        "never-audited": never,
        "stale": stale,
        "clean": audited_clean,
    }

    for row in rows:
        reason, candidate = _classify_row(row, commits_cache)
        buckets[reason].append(candidate)

    never = _round_robin_by_parent_dir(never, start_offset=_pick_counter(conn, audit_type))
    stale.sort(key=lambda c: (-c.commits_since_audit, c.path))
    audited_clean.sort(key=lambda c: (c.last_audited_at or "", c.path))

    if only_never:
        ordered = never
    elif only_stale:
        ordered = stale
    else:
        ordered = never + stale + audited_clean

    return ordered[:limit] if limit >= 0 else ordered


def done(
    conn: sqlite3.Connection,
    path: str,
    audit_type: str,
    *,
    commit: str | None = None,
    note: str | None = None,
    records_dir: Path | None = None,
) -> None:
    """Upsert an audit record at the given commit (defaults to current HEAD).

    Writes to the JSON source of truth at
    ``<repo>/docs/work/audits/records/<audit_type>.json`` and refreshes the
    SQLite cache row. When ``note`` is ``None`` on re-audit, the
    existing note (if any) is preserved; pass an explicit empty
    string to clear it. Raises ``ValueError`` if the path is not
    applicable for ``audit_type``.
    """
    applicable = conn.execute(
        "SELECT 1 FROM path_audit_applicability WHERE path = ? AND audit_type = ?",
        (path, audit_type),
    ).fetchone()
    if applicable is None:
        raise ValueError(
            f"path {path!r} is not applicable for audit type {audit_type!r}; "
            "run refresh or check the config"
        )
    sha = commit or git_utils.head_sha()
    now = datetime.now(UTC).isoformat()
    next_counter = _pick_counter(conn, audit_type) + 1

    # Records are the source of truth; write them first so a crash between
    # writes leaves the cache stale-but-rebuildable rather than the
    # source missing a recorded audit.
    records.write_record(
        audit_type,
        path,
        last_audited_at=now,
        last_audit_commit=sha,
        notes=note,
        pick_counter=next_counter,
        records_dir=records_dir,
    )
    with conn:
        conn.execute(
            """
            INSERT INTO audits (path, audit_type, last_audited_at, last_audit_commit, notes)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(path, audit_type) DO UPDATE SET
              last_audited_at = excluded.last_audited_at,
              last_audit_commit = excluded.last_audit_commit,
              notes = COALESCE(excluded.notes, audits.notes)
            """,
            (path, audit_type, now, sha, note),
        )
        conn.execute(
            """
            INSERT INTO audit_type_state (audit_type, pick_counter)
            VALUES (?, ?)
            ON CONFLICT(audit_type) DO UPDATE SET
              pick_counter = excluded.pick_counter
            """,
            (audit_type, next_counter),
        )


def status(
    conn: sqlite3.Connection,
    audit_type: str,
    *,
    kind: PathKind | None = None,
    path_prefix: str | None = None,
) -> AuditTypeStatus:
    """Summary counts for one audit type.

    ``kind`` optionally restricts to one kind; ``path_prefix`` optionally
    restricts to a subtree (the path itself plus descendants).
    """
    rows = _applicable_rows(conn, audit_type, kind=kind, path_prefix=path_prefix)
    commits_cache: dict[tuple[str, str], int] = {}
    total = len(rows)
    audited = 0
    stale = 0
    for row in rows:
        reason, _ = _classify_row(row, commits_cache)
        if reason != "never-audited":
            audited += 1
        if reason == "stale":
            stale += 1
    return AuditTypeStatus(
        audit_type=audit_type,
        total=total,
        audited=audited,
        never=total - audited,
        stale=stale,
    )


def list_types(conn: sqlite3.Connection) -> list[str]:
    """All audit types that currently have at least one applicable path."""
    rows = conn.execute(
        "SELECT DISTINCT audit_type FROM path_audit_applicability ORDER BY audit_type"
    ).fetchall()
    return [row["audit_type"] for row in rows]
