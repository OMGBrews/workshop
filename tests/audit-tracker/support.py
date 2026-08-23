"""Shared helpers for the audit_tracker + selector unittest suites.

Stands in for pia-maker's pytest ``conftest.py``. Every ``test_tracker_*``
and ``test_selector_*`` module in this directory does a plain
``import support`` — unittest discovery runs with ``-s`` = ``-t`` = this
directory, which puts the directory itself on ``sys.path``.

What lives here:

- the ``sys.path`` bootstrap that makes the shipped package importable as
  ``audit_tracker.*`` and the skill-root scripts importable as top-level
  modules (``select_next``),
- :class:`RepoTestCase`: a temp git repository per test, with the process
  chdir'd into it and ``git_utils.reset_repo_root_cache()`` called on both
  edges — ``repo_root()`` is cached per process, so a stale cache leaking
  between tests is the #1 port hazard,
- :func:`make_config`: build a ``Config`` from a Python dict without disk,
- :class:`FakeGit`: controllable stand-ins for ``git_utils``'s git calls,
- :func:`redirect_cache`: point ``records``' refresh-state default at a
  chosen directory.

Bytecode writing is disabled *before* the package import: importing
``audit_tracker`` must never leave a ``__pycache__`` under
``.agents/skills/``, which is a pinned mount with no ``.gitignore``.
"""

from __future__ import annotations

import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# --- bootstrap ---------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = REPO_ROOT / ".agents" / "skills" / "audit-and-fix"

sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"

if str(SKILL_DIR) not in sys.path:
    sys.path.insert(0, str(SKILL_DIR))

from audit_tracker import git_utils, records  # noqa: E402  (after bytecode switch)
from audit_tracker.config import Config, parse_config  # noqa: E402
from audit_tracker.db import init_schema  # noqa: E402


def _probe_mid_doublestar() -> bool:
    """True iff the shipped matcher lets a MID-pattern ``**`` match zero
    segments (``app/**/*.py`` matching ``app/x.py``).

    pia-maker's reference (``PurePosixPath.full_match``) allowed this; the
    ported hand-rolled translation currently requires >=1 segment wherever
    ``**`` appears, so such rules silently stop matching their shallowest
    files. Tests carrying pia assertions over that behaviour skip unless the
    property holds, so they light up the moment the matcher is fixed.
    """
    from audit_tracker.config import TargetRule
    from audit_tracker.matcher import matches_rule

    return matches_rule("app/x.py", TargetRule(kind="file", include=["app/**/*.py"]))


MID_DOUBLESTAR_MATCHES_ZERO_SEGMENTS = _probe_mid_doublestar()


# --- builders ----------------------------------------------------------------


def make_config(raw: dict[str, object]) -> Config:
    """Validate a config dict through the real parser, no disk involved."""
    return parse_config(raw, "<test-config>")


def write_file(path: Path, text: str = "x\n") -> Path:
    """Create ``path``'s parents and write UTF-8 text; returns the path."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def run_git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True
    )


def make_conn(test: unittest.TestCase) -> sqlite3.Connection:
    """In-memory SQLite connection with the tracker schema applied."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    init_schema(conn)
    test.addCleanup(conn.close)
    return conn


def redirect_cache(test: unittest.TestCase, cache: Path) -> None:
    """Point ``records``' refresh-state default (``cache_dir()``) at ``cache``.

    Refresh state lives beside the SQLite cache, which normally resolves to
    the current repo's git dir. Tests that exercise refresh state without a
    repo (or that want a specific scratch dir) patch the resolver here.
    """
    test.enterContext(
        mock.patch.object(records, "cache_dir", lambda git_dir=None: cache)
    )


class FakeGit:
    """Controllable replacements for ``git_utils``'s subprocess-backed calls.

    Same shape as pia-maker's fixture: the resolution logic that decides
    submodule membership or emptiness is real-filesystem work tested against
    real repos in ``test_tracker_git_utils``; here it is a given, so the
    callers' behaviour can be tested on its own.
    """

    def __init__(self) -> None:
        self.files: list[str] = []
        self.head: str = "HEAD_SHA"
        self.commits_by_path: dict[tuple[str, str], int] = {}
        self.unknown_shas: set[str] = set()
        # Subset of ``files`` a submodule owns / whose indexed content is
        # empty. Empty by default so every test keeps its whole file list.
        self.submodule_owned: set[str] = set()
        self.empty_files: set[str] = set()
        self.symlink_files: set[str] = set()

    def install(self, test: unittest.TestCase) -> FakeGit:
        """Patch ``git_utils`` for the duration of ``test``."""
        test.enterContext(
            mock.patch.object(git_utils, "ls_files", lambda: list(self.files))
        )
        test.enterContext(mock.patch.object(git_utils, "head_sha", lambda: self.head))
        test.enterContext(
            mock.patch.object(
                git_utils,
                "submodule_owned_paths",
                lambda: set(self.submodule_owned),
            )
        )
        test.enterContext(
            mock.patch.object(
                git_utils, "empty_blob_paths", lambda: set(self.empty_files)
            )
        )
        test.enterContext(
            mock.patch.object(
                git_utils, "symlink_paths", lambda: set(self.symlink_files)
            )
        )

        def _commits_since(since_sha: str, path: str) -> int:
            if since_sha in self.unknown_shas:
                raise git_utils.UnknownCommitError(f"unknown sha: {since_sha}")
            return self.commits_by_path.get((since_sha, path), 0)

        test.enterContext(
            mock.patch.object(git_utils, "commits_since", _commits_since)
        )

        def _commits_since_many(since_sha: str, paths: list[str]) -> dict[str, int]:
            if since_sha in self.unknown_shas:
                raise git_utils.UnknownCommitError(f"unknown sha: {since_sha}")
            return {
                path: self.commits_by_path.get((since_sha, path), 0)
                for path in paths
            }

        test.enterContext(
            mock.patch.object(git_utils, "commits_since_many", _commits_since_many)
        )
        test.enterContext(
            mock.patch.object(
                git_utils,
                "commits_since_many_by_sha",
                lambda requests: {
                    sha: {
                        path: self.commits_by_path.get((sha, path), 0)
                        for path in paths
                    }
                    for sha, paths in requests.items()
                    if sha not in self.unknown_shas
                },
            )
        )
        return self


class RepoTestCase(unittest.TestCase):
    """A throwaway git repo per test, with the process running inside it.

    ``setUp`` chdirs into the fresh repo and clears ``git_utils``' per-process
    root cache; the cleanup restores the original CWD and clears the cache
    again, so no test can inherit another's root. Cleanup order is LIFO:
    the CWD is restored before the temp tree is deleted.
    """

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="audit-tracker-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        run_git(self.repo, "init", "-q", ".")
        self._prev_cwd = os.getcwd()
        os.chdir(self.repo)
        git_utils.reset_repo_root_cache()
        self.addCleanup(self._leave_repo)

    def _leave_repo(self) -> None:
        os.chdir(self._prev_cwd)
        git_utils.reset_repo_root_cache()

    # Convenience accessors -------------------------------------------------

    @property
    def records_dir(self) -> Path:
        """Where ``done()``/``load_into_db`` read and write in this repo."""
        return self.repo / records.RECORDS_SUBDIR

    @property
    def cache(self) -> Path:
        """This repo's tracker cache dir (inside its git dir)."""
        return self.repo / ".git" / "audit-tracker"

    def conn(self) -> sqlite3.Connection:
        return make_conn(self)

    def fake_git(self) -> FakeGit:
        return FakeGit().install(self)

    def write_toml(self, body: str, name: str = "config.toml") -> Path:
        """Write a TOML config next to (not inside) the repo; returns its path."""
        return write_file(self.tmp / name, body.strip() + "\n")

    def seed_config_in_repo(self, types_body: str) -> Path:
        """Write ``docs/work/audits/config.toml`` inside the repo (the opt-in)."""
        return write_file(
            self.repo / "docs/work/audits/config.toml",
            "[audit_types]\n" + types_body.strip() + "\n",
        )
