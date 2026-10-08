"""Audit tracker queries: next, done, status, list-types.

All queries read/write through a live SQLite connection. Staleness is
computed against git history (via ``git_utils``) so the DB does not need
to cache per-path mtimes.

Every row belongs to a repository — ``self`` (the control repository) or a
declared subject — and each repository's staleness is judged against its own
HEAD and history. Functions that read history take ``roots``, mapping a
repository name to its worktree root; omitted, only ``self`` is readable,
through the default control root.
"""

import hashlib
import sqlite3
from collections import defaultdict, deque
from collections.abc import Collection, Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from . import git_utils, records
from .config import ROOT, SELF_REPOSITORY, PathKind, Repository
from .repositories import RepositoryContext, control

AuditReason = Literal["never-audited", "stale", "clean"]


@dataclass(frozen=True)
class NextCandidate:
    """One row returned by :func:`next_paths`."""

    path: str
    kind: str
    last_audited_at: str | None
    commits_since_audit: int
    reason: AuditReason
    repository: str = SELF_REPOSITORY


@dataclass(frozen=True)
class AuditTypeStatus:
    """Summary counts for one audit type: total applicable vs audited, never, stale.

    ``repository`` names the repository counted, or is ``None`` when the
    counts span every repository.
    """

    audit_type: str
    total: int
    audited: int
    never: int
    stale: int
    repository: str | None = None


@dataclass(frozen=True)
class ValidatedPath:
    """Canonical, repo-owned path accepted for an explicit audit.

    ``path`` is relative to ``repository``'s own root.
    """

    path: str
    kind: PathKind
    repository: str = SELF_REPOSITORY


def _root_for(roots: Mapping[str, Path] | None, repository: str) -> Path | None:
    """The worktree root to read ``repository``'s history from."""
    if roots is not None and repository in roots:
        return roots[repository]
    if repository == SELF_REPOSITORY:
        return None  # git_utils' default: the control root
    raise ValueError(
        f"repository {repository!r} was not resolved for this query; "
        "pass its worktree root in roots"
    )


def _repository_label(repository: str) -> str:
    return "the repository" if repository == SELF_REPOSITORY else f"repository {repository!r}"


def canonicalize_explicit_path(
    raw: str, root: Path | None = None, repository: str = SELF_REPOSITORY
) -> tuple[str, Path]:
    """Return canonical repo-relative POSIX spelling and its lexical path.

    Relative paths are taken from ``root`` (default: the control root), not
    the process CWD. Absolute paths are accepted only when their lexical path
    is inside that root. The root itself canonicalizes to ``.``. Target
    resolution and ownership checks belong to :func:`validate_explicit_path`.
    """
    cleaned = raw.strip()
    if not cleaned:
        raise ValueError("path must not be empty")
    root = (root or git_utils.repo_root()).resolve()
    label = _repository_label(repository)
    supplied = Path(cleaned)
    lexical = supplied if supplied.is_absolute() else root / supplied
    lexical = Path(lexical.absolute())
    try:
        relative = lexical.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"path is outside {label}: {raw!r}") from exc
    if relative == Path("."):
        return ROOT, lexical
    if any(part == ".." for part in relative.parts):
        raise ValueError(f"path is outside {label}: {raw!r}")
    return relative.as_posix(), lexical


def _reject_subject_spelling(
    canonical: str, declared: Mapping[str, Repository]
) -> None:
    """Refuse a control-relative path that lands inside a declared subject.

    The subject's content belongs to the subject's history and records; a
    control-relative spelling would be checked against the wrong repository.
    """
    for declaration in declared.values():
        if canonical == declaration.path:
            raise ValueError(
                f"path {canonical!r} is the root of declared repository "
                f"{declaration.name!r}; pass --repository {declaration.name} "
                "with the path '.'"
            )
        if canonical.startswith(declaration.path + "/"):
            inner = canonical[len(declaration.path) + 1 :]
            raise ValueError(
                f"path {canonical!r} is inside declared repository "
                f"{declaration.name!r}; pass --repository {declaration.name} "
                f"with the subject-relative path {inner!r}"
            )


def validate_explicit_path(
    raw: str,
    *,
    conn: sqlite3.Connection | None = None,
    audit_type: str | None = None,
    expected_kind: PathKind | None = None,
    repository: RepositoryContext | None = None,
    declared: Mapping[str, Repository] | None = None,
) -> ValidatedPath:
    """Validate and canonicalize a user-supplied audit path.

    With ``conn=None`` this is the unconfigured path-only mode: ownership and
    tracking come directly from Git and no cache is created. With a connection,
    the refreshed path table is authoritative and ``audit_type`` additionally
    has to be applicable.

    ``repository`` selects a resolved subject; the path is then relative to
    its root. For the control repository, ``declared`` names the configured
    subjects so a control-relative path into one is refused with the
    spelling that would work.
    """
    context = repository or control()
    name = context.name
    root = context.root.resolve()
    label = _repository_label(name)
    canonical, lexical = canonicalize_explicit_path(raw, root, name)
    if context.is_self and declared:
        _reject_subject_spelling(canonical, declared)
    if canonical in git_utils.symlink_paths(root):
        raise ValueError(
            f"path {canonical!r} is a tracked symlink; audit its tracked target instead"
        )
    try:
        lexical.resolve(strict=False).relative_to(root)
    except ValueError as exc:
        raise ValueError(f"path resolves outside {label}: {raw!r}") from exc
    if not lexical.exists():
        hint = ""
        if context.declared_path and canonical.startswith(context.declared_path + "/"):
            hint = (
                f"; with --repository {name}, paths are relative to the "
                f"subject root, e.g. {canonical[len(context.declared_path) + 1 :]!r}"
            )
        raise ValueError(f"path does not exist: {canonical!r}{hint}")

    if conn is None:
        owned = git_utils.submodule_owned_paths(root) | git_utils.symlink_paths(root)
        files = set(git_utils.ls_files(root)) - owned
        directories: set[str] = {ROOT} if files else set()
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
            "SELECT kind FROM paths WHERE repository = ? AND path = ?", (name, canonical)
        ).fetchone()
        if row is None:
            raise ValueError(
                f"path {canonical!r} is not a tracked, repository-owned file or directory"
            )
        kind = row["kind"]
        if audit_type is not None:
            applicable = conn.execute(
                "SELECT 1 FROM path_audit_applicability "
                "WHERE repository = ? AND path = ? AND audit_type = ?",
                (name, canonical, audit_type),
            ).fetchone()
            if applicable is None:
                raise ValueError(
                    f"path {canonical!r} is not applicable for audit type {audit_type!r}"
                )

    if expected_kind is not None and kind != expected_kind:
        raise ValueError(
            f"path {canonical!r} is a {kind}, not the requested {expected_kind}"
        )
    return ValidatedPath(path=canonical, kind=kind, repository=name)


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
    repository: str | None = None,
) -> list[sqlite3.Row]:
    """All applicable paths joined with their latest audit (if any).

    If ``kind`` is given, filter to only files or only directories.
    If ``path_prefix`` is given, include only the path itself and its
    descendants (``prefix`` or ``prefix/...``). If ``repository`` is given,
    include only that repository's rows; otherwise every repository's.
    """
    sql = """
        SELECT
          p.repository      AS repository,
          p.path            AS path,
          p.kind            AS kind,
          a.last_audited_at AS last_audited_at,
          a.last_audit_commit AS last_audit_commit
        FROM path_audit_applicability ap
        JOIN paths p ON p.repository = ap.repository AND p.path = ap.path
        LEFT JOIN audits a
               ON a.repository = ap.repository
              AND a.path = ap.path
              AND a.audit_type = ap.audit_type
        WHERE ap.audit_type = ?
    """
    params: list[str | PathKind] = [audit_type]
    if repository is not None:
        sql += " AND p.repository = ?"
        params.append(repository)
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


def _identity_key(repository: str, path: str) -> str:
    """Hash input for a path in a repository.

    The control repository keeps the bare path, so single-repository
    selection order is exactly what it always was. A subject's key adds its
    name behind a NUL — a byte no Git path contains — so equal relative
    paths in two repositories never tie or share a rotation slot.
    """
    if repository == SELF_REPOSITORY:
        return path
    return f"{repository}\0{path}"


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
        parent = str(Path(candidate.path).parent)
        grouped[_identity_key(candidate.repository, parent)].append(candidate)
    for group in grouped.values():
        group.sort(key=lambda c: _stable_hash(_identity_key(c.repository, c.path)))

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
    conn: sqlite3.Connection,
    rows: list[sqlite3.Row],
    roots: Mapping[str, Path] | None = None,
    subject_paths: Collection[str] = (),
) -> list[tuple[AuditReason, NextCandidate]]:
    """Classify audited rows with one Git history walk per repository and SHA.

    ``subject_paths`` are the control-relative paths of declared subjects;
    changes at exactly those names (gitlink moves) never stale a control
    repository audit. Neither do record-file changes for a directory above
    the records directory, the root included.
    """
    by_repository: dict[str, list[sqlite3.Row]] = defaultdict(list)
    for row in rows:
        by_repository[row["repository"]].append(row)
    classified: list[tuple[AuditReason, NextCandidate]] = []
    for repository, repository_rows in by_repository.items():
        classified.extend(
            _classify_repository_rows(
                conn,
                repository,
                repository_rows,
                _root_for(roots, repository),
                subject_paths if repository == SELF_REPOSITORY else (),
            )
        )
    return classified


def _classify_repository_rows(
    conn: sqlite3.Connection,
    repository: str,
    rows: list[sqlite3.Row],
    root: Path | None,
    ignore: Collection[str] = (),
) -> list[tuple[AuditReason, NextCandidate]]:
    """Classify one repository's audited rows against its own HEAD."""
    # Records live in the control repository; a subject's history has none.
    metadata_dir = records.RECORDS_SUBDIR if repository == SELF_REPOSITORY else None
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
                        repository=repository,
                    ),
                )
            )
        else:
            grouped[row["last_audit_commit"]].append(row)

    head = git_utils.head_sha(root)
    cached_rows = conn.execute(
        "SELECT audit_commit, path, commits_since FROM staleness_cache "
        "WHERE repository = ? AND head_commit = ?",
        (repository, head),
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
    computed = (
        git_utils.commits_since_many_by_sha(missing, root, ignore, metadata_dir)
        if missing
        else {}
    )
    cache_writes: list[tuple[str, str, str, str, int]] = []
    for sha, paths in missing.items():
        counts = computed.get(sha)
        for path in paths:
            value = counts[path] if counts is not None else _UNKNOWN_COMMIT
            cached[(sha, path)] = value
            cache_writes.append((repository, head, sha, path, value))
    if cache_writes:
        with conn:
            conn.executemany(
                "INSERT OR REPLACE INTO staleness_cache "
                "(repository, head_commit, audit_commit, path, commits_since) "
                "VALUES (?, ?, ?, ?, ?)",
                cache_writes,
            )
            # Prune only this repository's older HEADs: another repository's
            # rows are keyed to its own HEAD and stay valid.
            conn.execute(
                "DELETE FROM staleness_cache WHERE repository = ? AND head_commit <> ?",
                (repository, head),
            )

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
                        repository=repository,
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
    repository: str | None = None,
    roots: Mapping[str, Path] | None = None,
    subject_paths: Collection[str] = (),
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
    caller is responsible for normalizing via :func:`normalize_path_prefix`);
    ``repository`` restricts to one repository, and without it every
    repository's paths compete in one queue.

    ``limit`` truncates the result; ``limit=0`` returns an empty list and a
    negative ``limit`` returns every candidate.
    """
    rows = _applicable_rows(
        conn, audit_type, kind=kind, path_prefix=path_prefix, repository=repository
    )
    never = [
        NextCandidate(
            path=row["path"],
            kind=row["kind"],
            last_audited_at=None,
            commits_since_audit=0,
            reason="never-audited",
            repository=row["repository"],
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
    for reason, candidate in _classify_audited_rows(conn, audited_rows, roots, subject_paths):
        (stale if reason == "stale" else audited_clean).append(candidate)

    stale.sort(key=lambda c: (-c.commits_since_audit, c.path, c.repository))
    audited_clean.sort(key=lambda c: (c.last_audited_at or "", c.path, c.repository))

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
    repository: RepositoryContext | None = None,
) -> str:
    """Upsert an audit record at the given commit (defaults to current HEAD).

    Writes to the JSON source of truth at
    ``<repo>/docs/work/audits/records/<audit_type>.json`` — or, for a
    declared subject ``repository``, ``records/<name>/<audit_type>.json`` in
    the control repository — and refreshes the SQLite cache row. When
    ``note`` is ``None`` on re-audit, the existing note (if any) is
    preserved; pass an explicit empty string to clear it. Raises
    ``ValueError`` if the path is not applicable for ``audit_type``, or if a
    subject's commit is unknown there or not in the history of its HEAD.
    Returns the recorded commit.
    """
    name = repository.name if repository is not None else SELF_REPOSITORY
    applicable = conn.execute(
        "SELECT 1 FROM path_audit_applicability "
        "WHERE repository = ? AND path = ? AND audit_type = ?",
        (name, path, audit_type),
    ).fetchone()
    if applicable is None:
        where = "" if name == SELF_REPOSITORY else f" in repository {name!r}"
        raise ValueError(
            f"path {path!r}{where} is not applicable for audit type {audit_type!r}; "
            "run refresh or check the config"
        )
    if repository is None or repository.is_self:
        # The control repository keeps its historical contract: any commit
        # string is stored as given.
        sha = commit or git_utils.head_sha()
    else:
        sha = _verified_subject_commit(repository, commit)
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
        repository=name,
    )
    with conn:
        conn.execute(
            """
            INSERT INTO audits
              (repository, path, audit_type, last_audited_at, last_audit_commit, notes)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(repository, path, audit_type) DO UPDATE SET
              last_audited_at = excluded.last_audited_at,
              last_audit_commit = excluded.last_audit_commit,
              notes = COALESCE(excluded.notes, audits.notes)
            """,
            (name, path, audit_type, now, sha, note),
        )
    return sha


def _verified_subject_commit(repository: RepositoryContext, commit: str | None) -> str:
    """Full SHA of the subject commit to record, proven to be in its history.

    Local only: nothing is fetched, and whether the commit has landed
    anywhere is not this check's question. A record naming a commit that
    later leaves the subject's history (a rebase, a squash merge) is caught
    by staleness, which treats an unreachable audit commit as stale.
    """
    requested = commit or "HEAD"
    sha = git_utils.resolve_commit(repository.root, requested)
    if sha is None:
        raise ValueError(
            f"commit {requested!r} does not exist in repository {repository.name!r} "
            f"({repository.root})"
        )
    if not git_utils.is_ancestor_of_head(repository.root, sha):
        raise ValueError(
            f"commit {requested!r} is not in the history of repository "
            f"{repository.name!r}'s checked-out HEAD; record a commit that "
            "contains the reviewed content"
        )
    return sha


def status(
    conn: sqlite3.Connection,
    audit_type: str,
    *,
    kind: PathKind | None = None,
    path_prefix: str | None = None,
    repository: str | None = None,
    roots: Mapping[str, Path] | None = None,
    subject_paths: Collection[str] = (),
) -> AuditTypeStatus:
    """Summary counts for one audit type.

    ``kind`` optionally restricts to one kind; ``path_prefix`` optionally
    restricts to a subtree (the path itself plus descendants);
    ``repository`` optionally restricts to one repository.
    """
    rows = _applicable_rows(
        conn, audit_type, kind=kind, path_prefix=path_prefix, repository=repository
    )
    total = len(rows)
    never = sum(row["last_audited_at"] is None for row in rows)
    audited_rows = [row for row in rows if row["last_audited_at"] is not None]
    audited = len(audited_rows)
    stale = 0
    for reason, _ in _classify_audited_rows(conn, audited_rows, roots, subject_paths):
        if reason == "stale":
            stale += 1
    return AuditTypeStatus(
        audit_type=audit_type,
        total=total,
        audited=audited,
        never=never,
        stale=stale,
        repository=repository,
    )


def list_types(conn: sqlite3.Connection, repository: str | None = None) -> list[str]:
    """Audit types that currently have at least one applicable path
    (in ``repository``, when given)."""
    if repository is None:
        rows = conn.execute(
            "SELECT DISTINCT audit_type FROM path_audit_applicability ORDER BY audit_type"
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT DISTINCT audit_type FROM path_audit_applicability "
            "WHERE repository = ? ORDER BY audit_type",
            (repository,),
        ).fetchall()
    return [row["audit_type"] for row in rows]
