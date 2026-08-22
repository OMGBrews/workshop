"""Refresh: reconcile the ``paths`` and ``path_audit_applicability`` tables
with the current state of the git tree and the audit config.
"""

import sqlite3
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, datetime

from . import git_utils, records
from .config import Config, PathKind, TargetRule
from .matcher import matches_rule


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


def _rules_by_kind(config: Config) -> dict[PathKind, list[tuple[str, TargetRule]]]:
    """Index all rules by kind so path matching can skip irrelevant rules."""
    indexed: dict[PathKind, list[tuple[str, TargetRule]]] = {"file": [], "directory": []}
    for type_name, audit_type in config.audit_types.items():
        for rule in audit_type.targets:
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


def refresh(conn: sqlite3.Connection, config: Config) -> RefreshSummary:
    """Reconcile paths and applicability against the git tree. Returns counts."""
    now = datetime.now(UTC).isoformat()
    # Submodule-owned paths are dropped here rather than excluded per-type in
    # audits.yaml: globs match paths, but what makes these paths upstream-owned
    # is their link target, which no filename pattern can see. Dropping before
    # _derive_directories keeps a submodule root from contributing directories
    # nothing local lives in.
    owned = git_utils.submodule_owned_paths()
    files = [path for path in git_utils.ls_files() if path not in owned]
    directories = _derive_directories(files)

    current: dict[str, PathKind] = {}
    for file_path in files:
        current[file_path] = "file"
    for directory in directories:
        current[directory] = "directory"
    current_paths = set(current)

    existing_rows = conn.execute("SELECT path FROM paths").fetchall()
    existing = {row["path"] for row in existing_rows}

    to_add = current_paths - existing
    to_remove = existing - current_paths
    to_update = existing & current_paths

    rules_by_kind = _rules_by_kind(config)
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
    empty_files = git_utils.empty_blob_paths()
    applicability: list[tuple[str, str]] = [
        (path, type_name)
        for path, kind in current.items()
        if not (kind == "file" and path in empty_files)
        for type_name in _applicable_types(path, rules_by_kind[kind])
    ]

    with conn:
        conn.executemany(
            "INSERT INTO paths (path, kind, first_seen_at, last_seen_at) VALUES (?, ?, ?, ?)",
            [(path, current[path], now, now) for path in to_add],
        )
        # UPDATE sets kind too so a file↔directory flip at the same path is
        # reflected — otherwise paths.kind silently disagrees with applicability.
        conn.executemany(
            "UPDATE paths SET kind = ?, last_seen_at = ? WHERE path = ?",
            [(current[path], now, path) for path in to_update],
        )
        conn.executemany(
            "DELETE FROM paths WHERE path = ?",
            [(path,) for path in to_remove],
        )
        conn.execute("DELETE FROM path_audit_applicability")
        conn.executemany(
            "INSERT INTO path_audit_applicability (path, audit_type) VALUES (?, ?)",
            applicability,
        )

    records.write_refresh_state(
        last_refreshed_at=now,
        last_refresh_commit=git_utils.head_sha(),
    )

    return RefreshSummary(
        added_paths=len(to_add),
        removed_paths=len(to_remove),
        total_paths=len(current),
        applicability_rows=len(applicability),
    )
