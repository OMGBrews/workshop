"""Refresh: reconcile the ``paths`` and ``path_audit_applicability`` tables
with the current state of the git tree and the audit config.

Each repository — the control repository (``self``) and every declared
subject — is reconciled against its own ``git ls-files`` and only the target
rules that name it. Rows carry the repository, so refreshing one never
touches another's.
"""

import sqlite3
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime

from . import git_utils, records
from .config import Config, PathKind, TargetRule
from .matcher import matches_rule
from .repositories import RepositoryContext, resolve_all


@dataclass(frozen=True)
class RefreshSummary:
    """Counts from a refresh run; for CLI display and tests."""

    added_paths: int
    removed_paths: int
    total_paths: int
    applicability_rows: int


def _derive_directories(files: Iterable[str]) -> set[str]:
    """Every parent directory of any tracked file (repo-relative, POSIX)."""
    dirs: set[str] = set()
    for file_path in files:
        parts = file_path.split("/")
        for depth in range(1, len(parts)):
            dirs.add("/".join(parts[:depth]))
    return dirs


def _rules_by_kind(
    config: Config, repository: str
) -> dict[PathKind, list[tuple[str, TargetRule]]]:
    """Index ``repository``'s rules by kind so matching can skip the rest."""
    indexed: dict[PathKind, list[tuple[str, TargetRule]]] = {"file": [], "directory": []}
    for type_name, audit_type in config.audit_types.items():
        for rule in audit_type.targets:
            if rule.repository == repository:
                indexed[rule.kind].append((type_name, rule))
    return indexed


def _applicable_types(path: str, rules_for_kind: list[tuple[str, TargetRule]]) -> set[str]:
    """Audit type names whose rules match ``path``."""
    matched: set[str] = set()
    for type_name, rule in rules_for_kind:
        if type_name in matched:
            continue
        if matches_rule(path, rule):
            matched.add(type_name)
    return matched


def refresh(
    conn: sqlite3.Connection,
    config: Config,
    contexts: Sequence[RepositoryContext] | None = None,
) -> RefreshSummary:
    """Reconcile paths and applicability against Git. Returns summed counts.

    ``contexts`` defaults to the control repository plus every declared
    subject. Callers that resolved a narrower scope pass it, and only those
    repositories are reconciled and marked fresh. Rows for repositories the
    config no longer declares are always pruned.
    """
    if contexts is None:
        contexts = resolve_all(config)
    declared = config.repository_names()
    with conn:
        placeholders = ", ".join("?" for _ in declared)
        conn.execute(f"DELETE FROM paths WHERE repository NOT IN ({placeholders})", declared)
        conn.execute(
            f"DELETE FROM path_audit_applicability WHERE repository NOT IN ({placeholders})",
            declared,
        )
    added = removed = total = applicable = 0
    for context in contexts:
        summary = _refresh_repository(conn, config, context)
        added += summary.added_paths
        removed += summary.removed_paths
        total += summary.total_paths
        applicable += summary.applicability_rows
    return RefreshSummary(
        added_paths=added,
        removed_paths=removed,
        total_paths=total,
        applicability_rows=applicable,
    )


def _refresh_repository(
    conn: sqlite3.Connection, config: Config, context: RepositoryContext
) -> RefreshSummary:
    """Reconcile one repository's rows against its own Git tree."""
    now = datetime.now(UTC).isoformat()
    name = context.name
    root = context.root
    # Submodule-owned paths and every tracked symlink are dropped here rather
    # than excluded per-type in config: globs cannot see ownership or index
    # mode. Even a local symlink is unsafe because staleness follows the link
    # blob rather than its target. Dropping before _derive_directories keeps
    # excluded entries from contributing directories nothing auditable lives
    # in. A subject drops its own gitlinks the same way; a nested repository
    # becomes auditable only by being declared itself.
    owned = git_utils.submodule_owned_paths(root) | git_utils.symlink_paths(root)
    files = [path for path in git_utils.ls_files(root) if path not in owned]
    directories = _derive_directories(files)

    current: dict[str, PathKind] = {}
    for file_path in files:
        current[file_path] = "file"
    for directory in directories:
        current[directory] = "directory"
    current_paths = set(current)

    existing_rows = conn.execute(
        "SELECT path FROM paths WHERE repository = ?", (name,)
    ).fetchall()
    existing = {row["path"] for row in existing_rows}

    to_add = current_paths - existing
    to_remove = existing - current_paths
    to_update = existing & current_paths

    rules_by_kind = _rules_by_kind(config, name)
    # Empty files are withheld from applicability — auditing a zero-byte file
    # can only ever conclude "it's empty", and the repo's ~143 empty package
    # markers otherwise queue once per applicable type. Two things about the
    # placement are load-bearing, and both are the *opposite* of the submodule
    # rule above, so this cannot be tidied up beside it:
    #
    #   - It runs *after* _derive_directories. A submodule's directories are
    #     upstream's and should vanish with it; a directory holding an empty
    #     marker is ours, and must keep contributing to the directory-kind
    #     pools even if every file in it is empty.
    #   - It filters applicability, not `files`. Empty paths stay in `paths`,
    #     so the audits foreign key (which references paths(path)) still
    #     resolves and records.load_into_db keeps loading the audits already
    #     recorded against them, instead of reporting them as orphans "no
    #     longer in git" — which would be plainly false.
    empty_files = git_utils.empty_blob_paths(root)
    applicability: list[tuple[str, str, str]] = [
        (name, path, type_name)
        for path, kind in current.items()
        if not (kind == "file" and path in empty_files)
        for type_name in _applicable_types(path, rules_by_kind[kind])
    ]

    with conn:
        conn.executemany(
            "INSERT INTO paths (repository, path, kind, first_seen_at, last_seen_at) "
            "VALUES (?, ?, ?, ?, ?)",
            [(name, path, current[path], now, now) for path in to_add],
        )
        # UPDATE sets kind too so a file↔directory flip at the same path is
        # reflected — otherwise paths.kind silently disagrees with applicability.
        conn.executemany(
            "UPDATE paths SET kind = ?, last_seen_at = ? WHERE repository = ? AND path = ?",
            [(current[path], now, name, path) for path in to_update],
        )
        conn.executemany(
            "DELETE FROM paths WHERE repository = ? AND path = ?",
            [(name, path) for path in to_remove],
        )
        conn.execute("DELETE FROM path_audit_applicability WHERE repository = ?", (name,))
        conn.executemany(
            "INSERT INTO path_audit_applicability (repository, path, audit_type) "
            "VALUES (?, ?, ?)",
            applicability,
        )

    records.write_refresh_state(
        last_refreshed_at=now,
        last_refresh_commit=git_utils.head_sha(root),
        repository=name,
    )

    return RefreshSummary(
        added_paths=len(to_add),
        removed_paths=len(to_remove),
        total_paths=len(current),
        applicability_rows=len(applicability),
    )
