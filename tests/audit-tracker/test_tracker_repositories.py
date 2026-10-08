"""End-to-end tests for declared subject repositories, at the CLI boundary.

Every test builds a real control repository and a real nested Git repository
— a submodule added from a local upstream, or a plain nested clone — and
drives ``cli.main`` with the default config, records, and cache locations,
exactly as a consumer runs it from the control root. Nothing here fakes Git:
the properties under test (whose history decides staleness, which index
invalidates the cache, what a broken mount looks like) only exist in real
repositories.

The fixture, after ``setUp``::

    repo/                               control (self)
      tool.py                           [self: code-quality file]
      docs/work/audits/config.toml      declares [repositories.library]
      library/                          submodule -> upstream (subject)
        tool.py                         [library: same relative path as self]
        src/core.py
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sqlite3
import subprocess
import unittest
from pathlib import Path
from unittest import mock

import support

from audit_tracker import cli, git_utils, queries
from audit_tracker.config import SELF_REPOSITORY, TargetRule
from audit_tracker.db import SCHEMA_VERSION, default_db_path


CONFIG = """
[repositories.library]
path = "library"

[audit_types.code-quality]
[[audit_types.code-quality.targets]]
kind = "file"
include = ["*.py"]

[[audit_types.code-quality.targets]]
repository = "library"
kind = "file"
include = ["**/*.py"]

[[audit_types.code-quality.targets]]
repository = "library"
kind = "directory"
include = ["src"]
"""

IDENTITY = ("-c", "user.email=test@example.com", "-c", "user.name=Test")


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *IDENTITY, *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def commit_all(repo: Path, message: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", message)
    return git(repo, "rev-parse", "HEAD")


class SubjectRepositoryTestCase(support.RepoTestCase):
    """A control repository with ``library/`` as a real submodule subject."""

    config_text = CONFIG

    def setUp(self) -> None:
        super().setUp()
        self.upstream = self.tmp / "upstream"
        self.upstream.mkdir()
        git(self.upstream, "init", "-q", ".")
        support.write_file(self.upstream / "tool.py", "def tool():\n    return 1\n")
        support.write_file(self.upstream / "src/core.py", "VALUE = 1\n")
        commit_all(self.upstream, "upstream initial")

        support.write_file(self.repo / "tool.py", "def control_tool():\n    return 0\n")
        git(
            self.repo,
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            str(self.upstream),
            "library",
        )
        self.library = self.repo / "library"
        commit_all(self.repo, "control initial")
        self.write_config(self.config_text)

    # helpers -----------------------------------------------------------------

    def write_config(self, text: str) -> Path:
        return support.write_file(
            self.repo / "docs/work/audits/config.toml", text.strip() + "\n"
        )

    def run_cli(self, *args: str) -> tuple[int, str, str]:
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def next_json(self, *args: str) -> list[dict[str, object]]:
        code, out, err = self.run_cli("next", "code-quality", "-n", "50", "--format", "json", *args)
        self.assertEqual(code, 0, err)
        payload = json.loads(out)
        if payload["outcome"] == "empty":
            return []
        self.assertEqual(payload["outcome"], "selected")
        return payload["candidates"]

    def identities(self, *args: str) -> set[tuple[str, str]]:
        return {(c["repository"], c["path"]) for c in self.next_json(*args)}

    def record_file(self, repository: str = SELF_REPOSITORY, audit_type: str = "code-quality") -> Path:
        base = self.repo / "docs/work/audits/records"
        if repository != SELF_REPOSITORY:
            base = base / repository
        return base / f"{audit_type}.json"

    def read_record(self, repository: str = SELF_REPOSITORY) -> dict[str, dict[str, str]]:
        return json.loads(self.record_file(repository).read_text(encoding="utf-8"))["audits"]


class SelectionTest(SubjectRepositoryTestCase):
    def test_subject_files_are_selected_without_machinery_in_the_subject(self) -> None:
        identities = self.identities()
        self.assertEqual(
            identities,
            {
                ("self", "tool.py"),
                ("library", "tool.py"),
                ("library", "src/core.py"),
                ("library", "src"),
            },
        )
        # The subject gained nothing: no config, no records, no cache, no
        # modified or untracked file.
        self.assertEqual(git(self.library, "status", "--porcelain", "--ignored"), "")
        self.assertFalse((self.library / "docs").exists())
        self.assertFalse((Path(git(self.library, "rev-parse", "--absolute-git-dir")) / "audit-tracker").exists())
        # The control's own cache holds the derived state.
        self.assertTrue(default_db_path(git_utils.absolute_git_dir()).exists())

    def test_identical_relative_paths_never_collide(self) -> None:
        candidates = self.next_json()
        tool_rows = [c for c in candidates if c["path"] == "tool.py"]
        self.assertEqual(sorted(c["repository"] for c in tool_rows), ["library", "self"])

        code, _out, err = self.run_cli("done", "tool.py", "code-quality", "--repository", "library")
        self.assertEqual(code, 0, err)
        # Recording the subject's tool.py leaves the control's tool.py unaudited.
        self.assertEqual(self.identities("--never"), {
            ("self", "tool.py"),
            ("library", "src/core.py"),
            ("library", "src"),
        })
        self.assertFalse(self.record_file().exists())
        self.assertEqual(set(self.read_record("library")), {"tool.py"})

        code, out, err = self.run_cli("status", "code-quality")
        self.assertEqual(code, 0, err)
        self.assertIn("code-quality (repository self): total=1 audited=0 never=1 stale=0", out)
        self.assertIn("code-quality (repository library): total=3 audited=1 never=2 stale=0", out)

    def test_repository_flag_scopes_each_command(self) -> None:
        self.assertEqual(self.identities("--repository", "self"), {("self", "tool.py")})
        self.assertEqual(
            {path for repo, path in self.identities("--repository", "library")},
            {"tool.py", "src/core.py", "src"},
        )
        self.assertEqual(
            self.identities("--repository", "library", "--under", "src"),
            {("library", "src/core.py"), ("library", "src")},
        )

    def test_under_without_repository_is_refused(self) -> None:
        code, out, err = self.run_cli("next", "code-quality", "--under", "src", "--format", "json")
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn("--under needs --repository", err)
        code, out, err = self.run_cli("status", "code-quality", "--under", "src")
        self.assertEqual(code, 2)
        self.assertIn("--under needs --repository", err)

    def test_text_output_names_the_subject(self) -> None:
        code, out, err = self.run_cli("next", "code-quality", "-n", "50", "--repository", "library")
        self.assertEqual(code, 0, err)
        self.assertIn("library:src/core.py\t[file]\tnever audited", out.splitlines())

    def test_list_types_prints_one_row_per_repository_and_type(self) -> None:
        code, out, err = self.run_cli("list-types")
        self.assertEqual(code, 0, err)
        rows = [line for line in out.splitlines() if line.startswith("code-quality")]
        self.assertEqual(len(rows), 2)
        self.assertRegex(rows[0], r"^code-quality\s+self\s+configured\s+total=1 ")
        self.assertRegex(rows[1], r"^code-quality\s+library\s+configured\s+total=3 ")
        self.assertIn("Last refresh (library):", out)

    def test_unknown_repository_is_an_error(self) -> None:
        for command in (
            ["next", "code-quality", "--format", "json"],
            ["status", "code-quality"],
            ["validate-path", "tool.py", "code-quality"],
            ["done", "tool.py", "code-quality"],
        ):
            with self.subTest(command=command[0]):
                code, out, err = self.run_cli(*command, "--repository", "elsewhere")
                self.assertEqual(code, 2)
                self.assertEqual(out, "")
                self.assertIn("unknown repository 'elsewhere'", err)


class ValidationTest(SubjectRepositoryTestCase):
    def validate(self, *args: str) -> tuple[int, dict[str, object] | None, str]:
        code, out, err = self.run_cli("validate-path", *args, "--format", "json")
        return code, (json.loads(out) if code == 0 else None), err

    def test_subject_relative_and_absolute_spellings(self) -> None:
        for spelling in ("src/core.py", "./src/core.py", str(self.library / "src/core.py")):
            with self.subTest(spelling=spelling):
                code, payload, err = self.validate(
                    spelling, "code-quality", "--repository", "library"
                )
                self.assertEqual(code, 0, err)
                self.assertEqual(
                    payload,
                    {
                        "outcome": "valid",
                        "repository": "library",
                        "path": "src/core.py",
                        "kind": "file",
                        "audit_type": "code-quality",
                        "configured": True,
                    },
                )

    def test_control_spelling_into_a_subject_is_refused_with_a_hint(self) -> None:
        for spelling in ("library/src/core.py", str(self.library / "src/core.py")):
            with self.subTest(spelling=spelling):
                code, _payload, err = self.validate(spelling, "code-quality")
                self.assertEqual(code, 2)
                self.assertIn("inside declared repository 'library'", err)
                self.assertIn("--repository library", err)
                self.assertIn("'src/core.py'", err)

    def test_control_spelling_with_the_flag_explains_subject_relative_paths(self) -> None:
        code, _payload, err = self.validate(
            "library/src/core.py", "code-quality", "--repository", "library"
        )
        self.assertEqual(code, 2)
        self.assertIn("relative to the subject root", err)
        self.assertIn("'src/core.py'", err)

    def test_paths_outside_the_subject_are_refused(self) -> None:
        code, _payload, err = self.validate(
            str(self.repo / "tool.py"), "code-quality", "--repository", "library"
        )
        self.assertEqual(code, 2)
        self.assertIn("outside repository 'library'", err)
        code, _payload, err = self.validate("../tool.py", "code-quality", "--repository", "library")
        self.assertEqual(code, 2)
        self.assertIn("outside repository 'library'", err)

    def test_subject_symlinks_and_its_own_submodules_are_refused(self) -> None:
        (self.library / "alias.py").symlink_to("tool.py")
        git(self.library, "add", "alias.py")
        git(
            self.library,
            "update-index",
            "--add",
            "--cacheinfo",
            f"{git_utils.GITLINK_MODE},{'a' * 40},nested",
        )
        code, _payload, err = self.validate("alias.py", "code-quality", "--repository", "library")
        self.assertEqual(code, 2)
        self.assertIn("tracked symlink", err)
        self.assertNotIn(("library", "alias.py"), self.identities())
        self.assertNotIn(("library", "nested"), self.identities())


class RecordingTest(SubjectRepositoryTestCase):
    def test_done_records_the_subject_commit_in_a_control_owned_file(self) -> None:
        support.write_file(self.library / "src/core.py", "VALUE = 2\n")
        fixed = commit_all(self.library, "fix core")

        code, out, err = self.run_cli(
            "done", "src/core.py", "code-quality", "--repository", "library"
        )
        self.assertEqual(code, 0, err)
        self.assertIn(f"at {fixed}", out)
        self.assertIn("Record: docs/work/audits/records/library/code-quality.json", out)
        entry = self.read_record("library")["src/core.py"]
        self.assertEqual(entry["last_audit_commit"], fixed)
        self.assertFalse(self.record_file().exists())
        # The subject is unchanged by recording: only its own fix commit.
        self.assertEqual(git(self.library, "status", "--porcelain"), "")

    def test_done_accepts_an_abbreviated_subject_commit_and_stores_it_in_full(self) -> None:
        head = git(self.library, "rev-parse", "HEAD")
        code, _out, err = self.run_cli(
            "done", "src/core.py", "code-quality", "--repository", "library", "--commit", head[:10]
        )
        self.assertEqual(code, 0, err)
        self.assertEqual(self.read_record("library")["src/core.py"]["last_audit_commit"], head)

    def test_done_refuses_a_commit_unknown_to_the_subject(self) -> None:
        control_head = git(self.repo, "rev-parse", "HEAD")
        code, _out, err = self.run_cli(
            "done", "src/core.py", "code-quality", "--repository", "library", "--commit", control_head
        )
        self.assertEqual(code, 1)
        self.assertIn("does not exist in repository 'library'", err)
        self.assertFalse(self.record_file("library").exists())

    def test_done_refuses_a_commit_outside_the_subject_head_history(self) -> None:
        git(self.library, "switch", "-q", "-c", "side")
        support.write_file(self.library / "src/core.py", "VALUE = 3\n")
        side = commit_all(self.library, "side work")
        git(self.library, "switch", "-q", "-")
        code, _out, err = self.run_cli(
            "done", "src/core.py", "code-quality", "--repository", "library", "--commit", side
        )
        self.assertEqual(code, 1)
        self.assertIn("not in the history", err)
        self.assertFalse(self.record_file("library").exists())

    def test_self_keeps_accepting_any_commit_string(self) -> None:
        code, _out, err = self.run_cli("done", "tool.py", "code-quality", "--commit", "c1")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.read_record()["tool.py"]["last_audit_commit"], "c1")


class StalenessTest(SubjectRepositoryTestCase):
    def audit_both(self) -> None:
        for args in (
            ("tool.py", "code-quality"),
            ("src/core.py", "code-quality", "--repository", "library"),
        ):
            code, _out, err = self.run_cli("done", *args)
            self.assertEqual(code, 0, err)

    def stale(self) -> set[tuple[str, str]]:
        return self.identities("--stale")

    def test_subject_history_decides_subject_staleness(self) -> None:
        self.audit_both()
        self.assertEqual(self.stale(), set())

        support.write_file(self.library / "src/core.py", "VALUE = 9\n")
        commit_all(self.library, "later library change")
        candidates = {(c["repository"], c["path"]): c for c in self.next_json("--stale")}
        self.assertEqual(set(candidates), {("library", "src/core.py")})
        self.assertEqual(candidates[("library", "src/core.py")]["commits_since_audit"], 1)

    def test_changes_confined_to_another_repository_do_not_stale_an_audit(self) -> None:
        self.audit_both()
        # A control commit that changes the control's tool.py, plus moves the
        # gitlink: neither touches the library's history.
        support.write_file(self.library / "README.md", "docs\n")
        commit_all(self.library, "library docs")
        support.write_file(self.repo / "tool.py", "def control_tool():\n    return 5\n")
        commit_all(self.repo, "control change and gitlink bump")
        self.assertEqual(self.stale(), {("self", "tool.py")})

    def test_a_rewritten_subject_history_makes_the_record_stale(self) -> None:
        support.write_file(self.library / "src/core.py", "VALUE = 4\n")
        commit_all(self.library, "fix before push")
        code, _out, err = self.run_cli("done", "src/core.py", "code-quality", "--repository", "library")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.stale(), set())

        # A squash or rebase before landing replaces the recorded commit.
        git(self.library, "commit", "-q", "--amend", "-m", "rewritten")
        self.assertEqual(self.stale(), {("library", "src/core.py")})

        # Re-recording against the commit that is now checked out is cheap.
        code, _out, err = self.run_cli("done", "src/core.py", "code-quality", "--repository", "library")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.stale(), set())

    def test_staleness_cache_is_kept_per_repository(self) -> None:
        self.audit_both()
        self.stale()
        db = sqlite3.connect(default_db_path(git_utils.absolute_git_dir()))
        self.addCleanup(db.close)
        rows = db.execute("SELECT DISTINCT repository FROM staleness_cache").fetchall()
        self.assertEqual(sorted(row[0] for row in rows), ["library", "self"])
        # Querying one repository at a new HEAD prunes only that repository.
        support.write_file(self.library / "src/core.py", "VALUE = 8\n")
        commit_all(self.library, "move library head")
        self.identities("--repository", "library", "--stale")
        rows = db.execute("SELECT DISTINCT repository FROM staleness_cache").fetchall()
        self.assertEqual(sorted(row[0] for row in rows), ["library", "self"])


class CacheInvalidationTest(SubjectRepositoryTestCase):
    def notices(self, *args: str) -> list[str]:
        code, _out, err = self.run_cli("next", "code-quality", "--format", "json", *args)
        self.assertEqual(code, 0, err)
        return [line for line in err.splitlines() if "auto-refresh" in line]

    def test_first_run_refreshes_every_repository(self) -> None:
        self.assertEqual(
            self.notices(),
            [
                "audit_tracker: auto-refresh (empty)",
                "audit_tracker: auto-refresh (empty) for repository 'library'",
            ],
        )
        self.assertEqual(self.notices(), [])

    def test_subject_index_change_refreshes_only_the_subject(self) -> None:
        self.notices()
        support.write_file(self.library / "src/new.py", "NEW = 1\n")
        git(self.library, "add", "src/new.py")
        self.assertEqual(
            self.notices(),
            ["audit_tracker: auto-refresh (index-changed) for repository 'library'"],
        )
        self.assertIn(("library", "src/new.py"), self.identities())

    def test_subject_head_change_refreshes_only_the_subject(self) -> None:
        self.notices()
        support.write_file(self.library / "src/later.py", "LATER = 1\n")
        commit_all(self.library, "add later")
        self.assertEqual(
            self.notices(),
            ["audit_tracker: auto-refresh (head-changed) for repository 'library'"],
        )

    def test_control_change_refreshes_only_the_control(self) -> None:
        self.notices()
        support.write_file(self.repo / "extra.py", "EXTRA = 1\n")
        git(self.repo, "add", "extra.py")
        self.assertEqual(self.notices(), ["audit_tracker: auto-refresh (index-changed)"])

    def test_config_change_refreshes_every_repository(self) -> None:
        self.notices()
        self.write_config(CONFIG.replace('include = ["src"]', 'include = ["src", "missing"]'))
        self.assertEqual(
            self.notices(),
            [
                "audit_tracker: auto-refresh (config-changed)",
                "audit_tracker: auto-refresh (config-changed) for repository 'library'",
            ],
        )

    def test_a_scoped_command_never_marks_another_repository_fresh(self) -> None:
        self.notices()
        support.write_file(self.library / "src/new.py", "NEW = 1\n")
        git(self.library, "add", "src/new.py")
        support.write_file(self.repo / "extra.py", "EXTRA = 1\n")
        git(self.repo, "add", "extra.py")
        self.assertEqual(
            self.notices("--repository", "self"),
            ["audit_tracker: auto-refresh (index-changed)"],
        )
        self.assertEqual(
            self.notices(),
            ["audit_tracker: auto-refresh (index-changed) for repository 'library'"],
        )

    def test_a_cache_from_the_single_repository_schema_is_rebuilt(self) -> None:
        db_path = default_db_path(git_utils.absolute_git_dir())
        db_path.parent.mkdir(parents=True, exist_ok=True)
        old = sqlite3.connect(db_path)
        old.executescript(
            """
            CREATE TABLE paths (path TEXT PRIMARY KEY, kind TEXT NOT NULL,
              first_seen_at TEXT NOT NULL, last_seen_at TEXT NOT NULL);
            CREATE TABLE path_audit_applicability (path TEXT NOT NULL,
              audit_type TEXT NOT NULL, PRIMARY KEY (path, audit_type));
            CREATE TABLE audits (path TEXT NOT NULL, audit_type TEXT NOT NULL,
              last_audited_at TEXT NOT NULL, last_audit_commit TEXT, notes TEXT,
              PRIMARY KEY (path, audit_type));
            CREATE TABLE audit_type_state (audit_type TEXT PRIMARY KEY,
              pick_counter INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE staleness_cache (head_commit TEXT NOT NULL,
              audit_commit TEXT NOT NULL, path TEXT NOT NULL,
              commits_since INTEGER NOT NULL,
              PRIMARY KEY (head_commit, audit_commit, path));
            INSERT INTO paths VALUES ('tool.py', 'file', 'old', 'old');
            """
        )
        old.close()
        self.assertEqual(len(self.next_json()), 4)
        db = sqlite3.connect(db_path)
        self.addCleanup(db.close)
        self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], SCHEMA_VERSION)
        columns = [row[1] for row in db.execute("PRAGMA table_info(paths)")]
        self.assertIn("repository", columns)


class FailLoudTest(SubjectRepositoryTestCase):
    def assert_fails_loudly(self, expected: str, *extra: str) -> None:
        for command in (
            ["next", "code-quality", "--format", "json", *extra],
            ["status", "code-quality", *extra],
            ["list-types"],
            ["refresh"],
        ):
            if extra and command[0] in ("list-types", "refresh"):
                continue
            with self.subTest(command=command[0]):
                code, out, err = self.run_cli(*command)
                self.assertEqual(code, 2, err)
                self.assertEqual(out, "")
                self.assertIn(expected, err)

    def declare(self, name: str, path: str) -> None:
        self.write_config(
            CONFIG
            + f'\n[repositories.{name}]\npath = "{path}"\n'
            + f'\n[[audit_types.code-quality.targets]]\nrepository = "{name}"\n'
            + 'kind = "file"\ninclude = ["**/*.py"]\n'
        )

    def test_missing_subject(self) -> None:
        self.declare("ghost", "vendor/ghost")
        self.assert_fails_loudly("repository 'ghost' (path 'vendor/ghost') is missing")
        self.assert_fails_loudly("is missing", "--repository", "ghost")

    def test_uninitialized_submodule(self) -> None:
        self.next_json()  # a working cache first: failure must not fall back to it
        git(self.repo, "submodule", "deinit", "-q", "-f", "library")
        self.assertTrue(self.library.is_dir())
        self.assert_fails_loudly("is not a Git worktree root")
        code, out, err = self.run_cli(
            "done", "src/core.py", "code-quality", "--repository", "library"
        )
        self.assertEqual(code, 2)
        self.assertIn("is not a Git worktree root", err)

    def test_a_broken_subject_blocks_only_commands_that_read_it(self) -> None:
        git(self.repo, "submodule", "deinit", "-q", "-f", "library")
        self.assertEqual(self.identities("--repository", "self"), {("self", "tool.py")})
        code, _out, err = self.run_cli("done", "tool.py", "code-quality")
        self.assertEqual(code, 0, err)
        code, _out, err = self.run_cli("validate-path", "tool.py", "code-quality")
        self.assertEqual(code, 0, err)

    def test_plain_directory_is_not_a_repository(self) -> None:
        support.write_file(self.repo / "plain/module.py")
        commit_all(self.repo, "plain directory")
        self.declare("plain", "plain")
        self.assert_fails_loudly("repository 'plain' (path 'plain') is not a Git worktree root")

    def test_symlinked_subject_root(self) -> None:
        (self.repo / "linked").symlink_to("library")
        self.declare("linked", "linked")
        self.assert_fails_loudly("is a symlink")

    def test_symlinked_parent_component(self) -> None:
        nested = self.tmp / "elsewhere"
        nested.mkdir()
        git(nested, "init", "-q", "inner")
        support.write_file(nested / "inner/x.py")
        commit_all(nested / "inner", "outside")
        (self.repo / "mount").symlink_to(nested)
        self.declare("outside", "mount/inner")
        self.assert_fails_loudly("'mount' is a symlink")

    def test_subject_without_commits(self) -> None:
        git(self.repo, "init", "-q", "fresh")
        self.declare("fresh", "fresh")
        self.assert_fails_loudly("has no commits")

    def test_moved_subject(self) -> None:
        # The repository moved away; its old path now holds plain files the
        # control tracks.
        self.declare("moved", "old-home")
        support.write_file(self.repo / "old-home/leftover.py")
        self.assert_fails_loudly("repository 'moved' (path 'old-home') is not a Git worktree root")

    def test_config_errors(self) -> None:
        cases = {
            "escaping": ('[repositories.out]\npath = "../outside"\n', "plain descendant"),
            "absolute": ('[repositories.abs]\npath = "/tmp"\n', "relative to the control repository root"),
            "duplicate": (
                '[repositories.copy]\npath = "library"\n',
                "overlap",
            ),
            "nested": ('[repositories.inner]\npath = "library/src"\n', "overlap"),
            "reserved": ('[repositories.self]\npath = "library"\n', "reserved"),
            "bad name": ('[repositories."Lib_1"]\npath = "library"\n', "repository names use"),
            "undeclared": (
                '[[audit_types.code-quality.targets]]\nrepository = "nowhere"\n'
                'kind = "file"\ninclude = ["*.py"]\n',
                "undeclared repository 'nowhere'",
            ),
        }
        for label, (extra, expected) in cases.items():
            with self.subTest(case=label):
                self.write_config(CONFIG + "\n" + extra)
                code, out, err = self.run_cli("next", "code-quality", "--format", "json")
                self.assertEqual(code, 2, err)
                self.assertEqual(out, "")
                self.assertIn(expected, err)


class OwnershipTest(SubjectRepositoryTestCase):
    def test_undeclared_submodules_and_links_into_subjects_stay_excluded(self) -> None:
        other = self.tmp / "other-upstream"
        other.mkdir()
        git(other, "init", "-q", ".")
        support.write_file(other / "vendored.py")
        commit_all(other, "other initial")
        git(
            self.repo,
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            str(other),
            "vendor",
        )
        (self.repo / "alias.py").symlink_to("library/src/core.py")
        commit_all(self.repo, "undeclared submodule and a link into the subject")

        identities = self.identities()
        self.assertEqual(
            {identity for identity in identities if identity[0] == "self"},
            {("self", "tool.py")},
        )
        self.assertFalse(any(path.startswith(("vendor", "library")) for _repo, path in identities))
        code, _out, err = self.run_cli("validate-path", "vendor/vendored.py", "code-quality")
        self.assertEqual(code, 2)
        self.assertIn("not a tracked, repository-owned", err)

    def test_a_plain_nested_clone_is_a_subject_too(self) -> None:
        git(self.repo, "clone", "-q", str(self.upstream), "checkout")
        support.write_file(self.repo / ".gitignore", "/checkout/\n")
        commit_all(self.repo, "ignore the nested clone")
        self.write_config(
            CONFIG
            + '\n[repositories.checkout]\npath = "checkout"\n'
            + '\n[[audit_types.code-quality.targets]]\nrepository = "checkout"\n'
            + 'kind = "file"\ninclude = ["src/*.py"]\n'
        )
        self.assertEqual(
            self.identities("--repository", "checkout"),
            {("checkout", "src/core.py")},
        )


class LifecycleTest(SubjectRepositoryTestCase):
    def test_select_fix_commit_record_and_stale_again(self) -> None:
        """The whole loop a maintainer runs from the control root."""
        pick = self.next_json("--repository", "library", "--kind", "file")[0]
        self.assertEqual(pick["repository"], "library")
        path = pick["path"]

        # Review and fix inside the subject; commit there.
        target = self.library / path
        target.write_text(target.read_text(encoding="utf-8") + "# reviewed\n", encoding="utf-8")
        fixed = commit_all(self.library, f"fix: review {path}")

        code, _out, err = self.run_cli("done", path, "code-quality", "--repository", "library")
        self.assertEqual(code, 0, err)

        # Commit only the record in the control, by explicit pathspec; the
        # subject's now-moved gitlink stays out of the commit.
        record = "docs/work/audits/records/library/code-quality.json"
        git(self.repo, "add", "--", record)
        self.assertEqual(git(self.repo, "diff", "--cached", "--name-only"), record)
        git(self.repo, "commit", "-qm", f"chore(audits): record code-quality review of library:{path}")
        # The moved gitlink is left for the maintainer, unstaged.
        self.assertEqual(git(self.repo, "diff", "--name-only"), "library")
        self.assertEqual(git(self.repo, "diff", "--cached", "--name-only"), "")
        committed = json.loads(git(self.repo, "show", f"HEAD:{record}"))
        self.assertEqual(committed["audits"][path]["last_audit_commit"], fixed)

        self.assertNotIn(("library", path), self.identities("--stale"))
        self.assertNotIn(("library", path), self.identities("--never"))

        target.write_text(target.read_text(encoding="utf-8") + "# later\n", encoding="utf-8")
        commit_all(self.library, "later change")
        self.assertIn(("library", path), self.identities("--stale"))


class NestedSubjectPathTest(SubjectRepositoryTestCase):
    """A subject mounted inside a directory the control repository audits."""

    config_text = """
[repositories.inner]
path = "vendor/inner"

[audit_types.code-quality]
[[audit_types.code-quality.targets]]
kind = "file"
include = ["**/*.py"]

[[audit_types.code-quality.targets]]
kind = "directory"
include = ["vendor"]

[[audit_types.code-quality.targets]]
repository = "inner"
kind = "file"
include = ["**/*.py"]
"""

    def setUp(self) -> None:
        super().setUp()
        support.write_file(self.repo / "vendor/other.py", "OTHER = 1\n")
        git(
            self.repo,
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            str(self.upstream),
            "vendor/inner",
        )
        self.inner = self.repo / "vendor/inner"
        commit_all(self.repo, "vendor a second subject")

    def test_moving_a_subject_gitlink_does_not_stale_a_control_directory(self) -> None:
        code, _out, err = self.run_cli("done", "vendor", "code-quality")
        self.assertEqual(code, 0, err)
        support.write_file(self.inner / "src/core.py", "VALUE = 7\n")
        commit_all(self.inner, "subject change")
        git(self.repo, "add", "vendor/inner")
        git(self.repo, "commit", "-qm", "bump vendor/inner")
        self.assertNotIn(("self", "vendor"), self.identities("--stale"))
        self.assertIn(("inner", "src/core.py"), self.identities("--never"))

        # A change to content the control owns in that directory still counts.
        support.write_file(self.repo / "vendor/other.py", "OTHER = 2\n")
        commit_all(self.repo, "control change in vendor")
        self.assertIn(("self", "vendor"), self.identities("--stale"))


class RepositoryRootTest(SubjectRepositoryTestCase):
    """A repository's root is the directory ``.``, targeted only by name."""

    config_text = """
[repositories.library]
path = "library"

[audit_types.readme-quality]
[[audit_types.readme-quality.targets]]
kind = "directory"
include = [".", "docs"]

[[audit_types.readme-quality.targets]]
repository = "library"
kind = "directory"
include = ["."]

[audit_types.code-quality]
[[audit_types.code-quality.targets]]
repository = "library"
kind = "directory"
include = ["*", "**"]
"""

    def setUp(self) -> None:
        super().setUp()
        support.write_file(self.repo / "docs/guide.md", "guide\n")
        commit_all(self.repo, "control docs and audit config")

    def readme(self, *args: str) -> dict[tuple[str, str], dict[str, object]]:
        code, out, err = self.run_cli(
            "next", "readme-quality", "-n", "50", "--format", "json", *args
        )
        self.assertEqual(code, 0, err)
        payload = json.loads(out)
        return {(c["repository"], c["path"]): c for c in payload["candidates"]}

    def validate(self, *args: str) -> tuple[int, dict[str, object] | None, str]:
        code, out, err = self.run_cli("validate-path", *args, "--format", "json")
        return code, (json.loads(out) if code == 0 else None), err

    def done(self, *args: str) -> None:
        code, _out, err = self.run_cli("done", *args)
        self.assertEqual(code, 0, err)

    def test_roots_are_candidates_only_where_named(self) -> None:
        self.assertEqual(
            set(self.readme()), {("self", "."), ("self", "docs"), ("library", ".")}
        )
        self.assertEqual(self.readme()[("library", ".")]["kind"], "directory")
        # Wildcards that match every other directory never reach the root.
        directories = self.identities("--repository", "library", "--kind", "directory")
        self.assertIn(("library", "src"), directories)
        self.assertNotIn(("library", "."), directories)

    def test_root_validates_in_every_spelling(self) -> None:
        cases = [
            (spelling, "library") for spelling in (".", "./", str(self.library))
        ] + [(spelling, "self") for spelling in (".", str(self.repo))]
        for spelling, repository in cases:
            with self.subTest(spelling=spelling, repository=repository):
                code, payload, err = self.validate(
                    spelling, "readme-quality", "--repository", repository
                )
                self.assertEqual(code, 0, err)
                self.assertEqual(payload["repository"], repository)
                self.assertEqual(payload["path"], ".")
                self.assertEqual(payload["kind"], "directory")

    def test_control_spelling_of_a_subject_root_names_the_working_spelling(self) -> None:
        code, _payload, err = self.validate("library", "readme-quality")
        self.assertEqual(code, 2)
        self.assertIn("root of declared repository 'library'", err)
        self.assertIn("--repository library with the path '.'", err)

    def test_a_subject_root_goes_stale_on_any_subject_commit(self) -> None:
        self.done(".", "readme-quality", "--repository", "library")
        record = json.loads(
            self.record_file("library", "readme-quality").read_text(encoding="utf-8")
        )
        self.assertEqual(
            record["audits"]["."]["last_audit_commit"], git(self.library, "rev-parse", "HEAD")
        )
        self.assertNotIn(("library", "."), self.readme("--stale"))

        support.write_file(self.library / "tool.py", "def tool():\n    return 2\n")
        commit_all(self.library, "library change outside any README")
        stale = self.readme("--stale")
        self.assertIn(("library", "."), stale)
        self.assertEqual(stale[("library", ".")]["commits_since_audit"], 1)

    def test_the_control_root_survives_its_own_record_commit(self) -> None:
        self.done(".", "readme-quality")
        self.done("docs", "readme-quality")
        record = "docs/work/audits/records/readme-quality.json"
        git(self.repo, "add", "--", record)
        git(self.repo, "commit", "-qm", "chore(audits): record readme-quality reviews")
        self.assertEqual(self.readme("--stale"), {})

        # Moving a subject's gitlink changed the subject, not the control.
        support.write_file(self.library / "src/core.py", "VALUE = 3\n")
        commit_all(self.library, "subject change")
        git(self.repo, "add", "library")
        git(self.repo, "commit", "-qm", "bump library")
        self.assertEqual(self.readme("--stale"), {})

        support.write_file(self.repo / "tool.py", "def control_tool():\n    return 9\n")
        commit_all(self.repo, "control content change")
        self.assertEqual(set(self.readme("--stale")), {("self", ".")})


class EnvironmentIsolationTest(SubjectRepositoryTestCase):
    """A caller's repository-local Git variables describe the control
    repository; commands in a subject must not inherit them."""

    def test_git_dir_cannot_make_a_plain_directory_a_subject(self) -> None:
        support.write_file(self.repo / "plain/module.py")
        commit_all(self.repo, "plain directory")
        self.write_config(CONFIG + '\n[repositories.plain]\npath = "plain"\n')
        with mock.patch.dict(os.environ, {"GIT_DIR": str(self.repo / ".git")}):
            code, out, err = self.run_cli(
                "next", "code-quality", "--repository", "plain", "--format", "json"
            )
        self.assertEqual(code, 2, out)
        self.assertEqual(out, "")
        self.assertIn("is not a Git worktree root", err)

    def test_git_index_file_does_not_replace_the_subject_index(self) -> None:
        expected = {("library", "tool.py"), ("library", "src/core.py"), ("library", "src")}
        with mock.patch.dict(os.environ, {"GIT_INDEX_FILE": str(self.repo / ".git/index")}):
            self.assertEqual(self.identities("--repository", "library"), expected)


class ControlFilesUnderASubjectTest(support.RepoTestCase):
    def test_control_entries_under_a_declared_path_belong_to_the_subject(self) -> None:
        support.write_file(self.repo / "top.py")
        support.write_file(self.repo / "sub/a.py")
        commit_all(self.repo, "control tracks sub/ for now")
        # sub/ becomes its own repository while the control index still
        # lists sub/a.py.
        git(self.repo / "sub", "init", "-q", ".")
        commit_all(self.repo / "sub", "sub initial")
        support.write_file(
            self.repo / "docs/work/audits/config.toml",
            '[repositories.sub]\npath = "sub"\n\n'
            '[audit_types.code-quality]\n'
            'targets = [{ kind = "file", include = ["**/*.py"] },'
            ' { repository = "sub", kind = "file", include = ["*.py"] }]\n',
        )
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = cli.main(["next", "code-quality", "-n", "10", "--format", "json"])
        self.assertEqual(code, 0)
        identities = {(c["repository"], c["path"]) for c in json.loads(out.getvalue())["candidates"]}
        self.assertEqual(identities, {("self", "top.py"), ("sub", "a.py")})


class SingleRepositoryCompatibilityTest(support.RepoTestCase):
    """A config with no [repositories] behaves exactly as before."""

    def setUp(self) -> None:
        super().setUp()
        for name in ("a/one.py", "a/two.py", "b/three.py", "c/d/four.py", "top.py"):
            support.write_file(self.repo / name, f"# {name}\n")
        commit_all(self.repo, "initial")
        support.write_file(
            self.repo / "docs/work/audits/config.toml",
            '[audit_types.code-quality]\ntargets = [{ kind = "file", include = ["**/*.py"] }]\n',
        )

    def run_cli(self, *args: str) -> tuple[int, str, str]:
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_selection_order_is_the_historical_hash_order(self) -> None:
        import hashlib
        from collections import defaultdict, deque

        def legacy(paths: list[str]) -> list[str]:
            digest = lambda s: hashlib.sha256(s.encode()).hexdigest()  # noqa: E731
            grouped: dict[str, list[str]] = defaultdict(list)
            for path in paths:
                grouped[str(Path(path).parent)].append(path)
            queues = {d: deque(sorted(g, key=digest)) for d, g in grouped.items()}
            rotation = deque(sorted(queues, key=digest))
            ordered: list[str] = []
            while rotation:
                directory = rotation.popleft()
                ordered.append(queues[directory].popleft())
                if queues[directory]:
                    rotation.append(directory)
            return ordered

        code, out, err = self.run_cli("next", "code-quality", "-n", "10")
        self.assertEqual(code, 0, err)
        paths = [line.split("\t")[0] for line in out.splitlines()]
        self.assertEqual(paths, legacy(["a/one.py", "a/two.py", "b/three.py", "c/d/four.py", "top.py"]))

    def test_records_state_and_text_keep_their_shapes(self) -> None:
        code, out, err = self.run_cli("done", "top.py", "code-quality")
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "Marked top.py as audited for code-quality.\n")
        self.assertTrue((self.repo / "docs/work/audits/records/code-quality.json").is_file())
        self.assertEqual(
            sorted(p.name for p in (self.repo / "docs/work/audits/records").iterdir()),
            ["code-quality.json"],
        )
        state = json.loads((self.cache / "refresh-state.json").read_text(encoding="utf-8"))
        self.assertEqual(
            set(state),
            {"last_refreshed_at", "last_refresh_commit", "config_digest", "index_fingerprint"},
        )
        code, out, err = self.run_cli("status", "code-quality")
        self.assertEqual(code, 0, err)
        self.assertEqual(out, "code-quality: total=5 audited=1 never=4 stale=0\n")
        code, out, err = self.run_cli("list-types")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith("Last refresh: "))
        self.assertRegex(out, r"\ncode-quality\s+configured\s+total=5 audited=1")

    def test_under_still_works_without_repository(self) -> None:
        code, out, err = self.run_cli("next", "code-quality", "-n", "10", "--under", "a")
        self.assertEqual(code, 0, err)
        self.assertEqual(sorted(line.split("\t")[0] for line in out.splitlines()), ["a/one.py", "a/two.py"])

    def test_target_rules_default_to_the_control_repository(self) -> None:
        rule = TargetRule(kind="file", include=["*.py"])
        self.assertEqual(rule.repository, SELF_REPOSITORY)


if __name__ == "__main__":
    unittest.main()
