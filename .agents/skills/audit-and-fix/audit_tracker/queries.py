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


@dataclass(frozen=True)
class ValidatedPath:
    """Canonical, repo-owned path accepted for an explicit audit."""

    path: str
    kind: PathKind


def canonicalize_explicit_path(raw: str) -> tuple[str, Path]:
    """Return canonical repo-relative POSIX spelling and its lexical path.

    Absolute paths are accepted only when their lexical path is inside the
    repository. Target resolution and ownership checks belong to
    :func:`validate_explicit_path`.
    """
    cleaned = raw.strip()
    if not cleaned:
        raise ValueError("path must not be empty")
    root = git_utils.repo_root().resolve()
    supplied = Path(cleaned)
    lexical = supplied if supplied.is_absolute() else root / supplied
    lexical = Path(lexical.absolute())
    try:
        relative = lexical.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"path is outside the repository: {raw!r}") from exc
    if relative == Path("."):
        raise ValueError("the repository root is not an auditable tracked path")
    if any(part == ".." for part in relative.parts):
        raise ValueError(f"path is outside the repository: {raw!r}")
    return relative.as_posix(), lexical


def validate_explicit_path(
    raw: str,
    *,
    conn: sqlite3.Connection | None = None,
    audit_type: str | None = None,
    expected_kind: PathKind | None = None,
) -> ValidatedPath:
    """Validate and canonicalize a user-supplied audit path.

    With ``conn=None`` this is the unconfigured path-only mode: ownership and
    tracking come directly from Git and no cache is created. With a connection,
    the refreshed path table is authoritative and ``audit_type`` additionally
    has to be applicable.
    """
    canonical, lexical = canonicalize_explicit_path(raw)
    if canonical in git_utils.symlink_paths():
        raise ValueError(
            f"path {canonical!r} is a tracked symlink; audit its tracked target instead"
        )
    root = git_utils.repo_root().resolve()
    try:
        lexical.resolve(strict=False).relative_to(root)
    except ValueError as exc:
        raise ValueError(f"path resolves outside the repository: {raw!r}") from exc
    if not lexical.exists():
        raise ValueError(f"path does not exist: {canonical!r}")

    if conn is None:
        owned = git_utils.submodule_owned_paths() | git_utils.symlink_paths()
        files = set(git_utils.ls_files()) - owned
        directories: set[str] = set()
        for file_path in files:
            parts = file_path.split("/")
            directories.update("/".join(parts[:depth]) for depth in range(1, len(parts)))
        if canonical in files:
            kind: PathKind = "file"
        elif canonical in directories:
            kind = "directory"
        else:
            raise ValueError(
                f"path {canonical!r} is not a tracked, repository-owned file or directory"
            )
    else:
        row = conn.execute(
            "SELECT kind FROM paths WHERE path = ?", (canonical,)
        ).fetchone()
        if row is None:
            raise ValueError(
                f"path {canonical!r} is not a tracked, repository-owned file or directory"
            )
        kind = row["kind"]
        if audit_type is not None:
            applicable = conn.execute(
                "SELECT 1 FROM path_audit_applicability WHERE path = ? AND audit_type = ?",
                (canonical, audit_type),
            ).fetchone()
            if applicable is None:
                raise ValueError(
                    f"path {canonical!r} is not applicable for audit type {audit_type!r}"
                )

    if expected_kind is not None and kind != expected_kind:
        raise ValueError(
            f"path {canonical!r} is a {kind}, not the requested {expected_kind}"
        )
    return ValidatedPath(path=canonical, kind=kind)


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
    candidates: list[NextCandidate],
) -> list[NextCandidate]:
    """Interleave candidates so consecutive picks come from different parent dirs.

    Ordering is deterministic (same path set → same output) but uniform:
    both the rotation of directories and the order of
    files within a directory use ``sha256(path)`` as the sort key, avoiding
    alphabetical clustering (e.g. ``__init__.py`` always landing first
    because ``_`` sorts before letters).

    Completing a selected path removes it from the never-audited bucket, so
    the next deterministic ordering naturally advances without shared mutable
    rotation state.
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
    rotation: deque[str] = deque(dirs_sorted)
    interleaved: list[NextCandidate] = []
    while rotation:
        directory = rotation.popleft()
        interleaved.append(queues[directory].popleft())
        if queues[directory]:
            rotation.append(directory)
    return interleaved


_UNKNOWN_COMMIT = -1
"""Sentinel stored in the ``commits_since`` cache when the recorded SHA is
no longer present in the repo. Classified as stale so the path re-surfaces
for re-audit — we cannot prove the prior audit is current."""


def _classify_audited_rows(
    conn: sqlite3.Connection, rows: list[sqlite3.Row]
) -> list[tuple[AuditReason, NextCandidate]]:
    """Classify audited rows with one Git history walk per recorded SHA."""
    grouped: dict[str, list[sqlite3.Row]] = defaultdict(list)
    classified: list[tuple[AuditReason, NextCandidate]] = []
    for row in rows:
        if not row["last_audit_commit"]:
            classified.append(
                (
                    "stale",
                    NextCandidate(
                        path=row["path"],
                        kind=row["kind"],
                        last_audited_at=row["last_audited_at"],
                        commits_since_audit=0,
                        reason="stale",
                    ),
                )
            )
        else:
            grouped[row["last_audit_commit"]].append(row)

    head = git_utils.head_sha()
    cached_rows = conn.execute(
        "SELECT audit_commit, path, commits_since FROM staleness_cache WHERE head_commit = ?",
        (head,),
    ).fetchall()
    cached = {
        (row["audit_commit"], row["path"]): row["commits_since"]
        for row in cached_rows
    }
    missing = {
        sha: [row["path"] for row in sha_rows if (sha, row["path"]) not in cached]
        for sha, sha_rows in grouped.items()
    }
    missing = {sha: paths for sha, paths in missing.items() if paths}
    computed = git_utils.commits_since_many_by_sha(missing) if missing else {}
    cache_writes: list[tuple[str, str, str, int]] = []
    for sha, paths in missing.items():
        counts = computed.get(sha)
        for path in paths:
            value = counts[path] if counts is not None else _UNKNOWN_COMMIT
            cached[(sha, path)] = value
            cache_writes.append((head, sha, path, value))
    if cache_writes:
        with conn:
            conn.executemany(
                "INSERT OR REPLACE INTO staleness_cache "
                "(head_commit, audit_commit, path, commits_since) VALUES (?, ?, ?, ?)",
                cache_writes,
            )
            conn.execute("DELETE FROM staleness_cache WHERE head_commit <> ?", (head,))

    for sha, sha_rows in grouped.items():
        paths = [row["path"] for row in sha_rows]
        counts = {path: cached[(sha, path)] for path in paths}
        for row in sha_rows:
            commits = counts[row["path"]]
            reason: AuditReason = (
                "stale" if commits == _UNKNOWN_COMMIT or commits > 0 else "clean"
            )
            classified.append(
                (
                    reason,
                    NextCandidate(
                        path=row["path"],
                        kind=row["kind"],
                        last_audited_at=row["last_audited_at"],
                        commits_since_audit=max(commits, 0),
                        reason=reason,
                    ),
                )
            )
    return classified


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
    never = [
        NextCandidate(
            path=row["path"],
            kind=row["kind"],
            last_audited_at=None,
            commits_since_audit=0,
            reason="never-audited",
        )
        for row in rows
        if row["last_audited_at"] is None
    ]
    never = _round_robin_by_parent_dir(never)

    # The default queue always prefers never-audited paths. If that bucket can
    # satisfy the requested limit, do not inspect Git history for thousands of
    # audited rows that cannot affect the answer.
    if only_never:
        return never[:limit] if limit >= 0 else never
    if not only_stale and limit >= 0 and len(never) >= limit:
        return never[:limit]

    stale: list[NextCandidate] = []
    audited_clean: list[NextCandidate] = []
    audited_rows = [row for row in rows if row["last_audited_at"] is not None]
    for reason, candidate in _classify_audited_rows(conn, audited_rows):
        (stale if reason == "stale" else audited_clean).append(candidate)

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
    # Records are the source of truth; write them first so a crash between
    # writes leaves the cache stale-but-rebuildable rather than the
    # source missing a recorded audit.
    records.write_record(
        audit_type,
        path,
        last_audited_at=now,
        last_audit_commit=sha,
        notes=note,
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
    total = len(rows)
    never = sum(row["last_audited_at"] is None for row in rows)
    audited_rows = [row for row in rows if row["last_audited_at"] is not None]
    audited = len(audited_rows)
    stale = 0
    for reason, _ in _classify_audited_rows(conn, audited_rows):
        if reason == "stale":
            stale += 1
    return AuditTypeStatus(
        audit_type=audit_type,
        total=total,
        audited=audited,
        never=never,
        stale=stale,
    )


def list_types(conn: sqlite3.Connection) -> list[str]:
    """All audit types that currently have at least one applicable path."""
    rows = conn.execute(
        "SELECT DISTINCT audit_type FROM path_audit_applicability ORDER BY audit_type"
    ).fetchall()
    return [row["audit_type"] for row in rows]
