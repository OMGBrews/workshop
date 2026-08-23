"""Integration tests for the audit tracker CLI — the auto-refresh decision
that runs at the start of every invocation, plus the not-opted-in gate that
precedes everything else.

Ported from pia-maker's ``test_cli.py`` and extended for the new contract:
with no ``docs/work/audits/config.toml`` and no ``--config``, every command —
including ``done`` — exits 4 having created nothing, because "not opted in"
must be distinguishable from both "no candidates" (0) and a broken tracker
(1).
"""


import support

import contextlib
import io
import json
import unittest
from pathlib import Path
from unittest import mock

from audit_tracker import cli, records
from audit_tracker.config import default_config_path
from audit_tracker.db import connect, init_schema
from audit_tracker.refresh import RefreshSummary


# The shipped prompt vocabulary is closed: CLI tests configure code-quality,
# which has real prompt files, rather than pia's invented "code" type.
CONFIG_TOML = """
[audit_types.code-quality]
targets = [{ kind = "file", include = ["*.py"] }]
"""


class RefreshSpy:
    """Replace ``cli.refresh`` to count invocations + capture state writes
    matching the production wiring (so ``read_refresh_state()`` reflects each
    spied refresh).
    """

    def __init__(self, head_fn: support.FakeGit | None = None) -> None:
        self.calls = 0
        self.head_fn = head_fn

    def __call__(self, conn, _config) -> RefreshSummary:
        self.calls += 1
        # Match real refresh: seed at least one path so subsequent
        # ``_auto_refresh_reason`` calls don't fire the ``"empty"`` reason.
        conn.execute(
            "INSERT OR IGNORE INTO paths (path, kind, first_seen_at, last_seen_at) "
            "VALUES ('placeholder.py', 'file', 'now', 'now')"
        )
        conn.commit()
        head = self.head_fn.head if self.head_fn else "HEAD"
        records.write_refresh_state(
            last_refreshed_at="2026-05-11T00:00:00+00:00",
            last_refresh_commit=head,
        )
        return RefreshSummary(added_paths=1, removed_paths=0, total_paths=1, applicability_rows=1)


class CliTestBase(support.RepoTestCase):
    """Common fixtures: a TOML config + --db/--config args, all under tmp."""

    def setUp(self) -> None:
        super().setUp()
        self.audit_config = support.write_file(self.tmp / "audits.toml", CONFIG_TOML)
        self.db_path = self.tmp / "audits.db"
        self.cli_args = ["--db", str(self.db_path), "--config", str(self.audit_config)]

    def run_main(self, *args: str) -> tuple[int, str]:
        """Run cli.main capturing stderr; returns (exit code, stderr)."""
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = cli.main([*self.cli_args, *args])
        return code, err.getvalue()


class AutoRefreshTest(CliTestBase):
    # 1. fresh DB + no recorded state → auto-refresh fires --------------------
    def test_auto_refreshes_on_first_run(self) -> None:
        fake = self.fake_git()
        fake.files = ["a.py"]
        fake.head = "FIRST_HEAD"
        spy = RefreshSpy(fake)
        with mock.patch.object(cli, "refresh", spy), contextlib.redirect_stdout(io.StringIO()):
            code, err = self.run_main("list-types")

        self.assertEqual(code, 0)
        self.assertEqual(spy.calls, 1)
        self.assertIn("auto-refresh (empty)", err)

    # 2. same HEAD again → no refresh cost -------------------------------------
    def test_skips_auto_refresh_when_head_unchanged(self) -> None:
        fake = self.fake_git()
        fake.files = ["a.py"]
        fake.head = "SAME_HEAD"
        spy = RefreshSpy(fake)
        patch_refresh = mock.patch.object(cli, "refresh", spy)
        quiet = contextlib.redirect_stdout(io.StringIO())
        with patch_refresh, quiet:
            self.run_main("list-types")  # primes state
            code, err = self.run_main("list-types")

        self.assertEqual(code, 0)
        self.assertEqual(spy.calls, 1)
        self.assertNotIn("auto-refresh", err)

    # 3. HEAD moving since last refresh → reconcile automatically -------------
    def test_auto_refreshes_when_head_changes(self) -> None:
        fake = self.fake_git()
        fake.files = ["a.py"]
        fake.head = "ORIGINAL"
        spy = RefreshSpy(fake)
        with mock.patch.object(cli, "refresh", spy), contextlib.redirect_stdout(io.StringIO()):
            self.run_main("list-types")
            fake.head = "ADVANCED"
            code, err = self.run_main("list-types")

        self.assertEqual(code, 0)
        self.assertEqual(spy.calls, 2)
        self.assertIn("auto-refresh (head-changed)", err)

    # 4. explicit `refresh`: the auto-refresh check is skipped -----------------
    def test_explicit_refresh_does_not_double_run(self) -> None:
        """Explicit ``refresh`` subcommand: the auto-refresh check is skipped
        so we don't pay the cost twice in one invocation."""
        fake = self.fake_git()
        fake.files = ["a.py"]
        fake.head = "HEAD_A"
        spy = RefreshSpy(fake)
        with mock.patch.object(cli, "refresh", spy), contextlib.redirect_stdout(io.StringIO()):
            self.run_main("list-types")  # primes state
            fake.head = "HEAD_B"
            code, err = self.run_main("refresh")

        self.assertEqual(code, 0)
        # Two refreshes total: one for the initial empty-DB call, one for the
        # explicit refresh. The HEAD-mismatch auto-refresh must NOT fire.
        self.assertEqual(spy.calls, 2)
        self.assertNotIn("auto-refresh", err)

    # 5. pre-existing DB but no refresh state (upgrade) → one auto-refresh ----
    def test_first_run_after_upgrade(self) -> None:
        """Pre-existing DB but no refresh-state file (upgrade from a version
        that didn't persist it) → auto-refresh fires once."""
        fake = self.fake_git()
        fake.files = ["a.py"]
        fake.head = "HEAD"

        # Simulate an old-version DB by directly inserting a path so the
        # ``"empty"`` reason doesn't fire — but don't write the state file.
        conn = connect(Path(self.cli_args[1]))
        init_schema(conn)
        conn.execute(
            "INSERT INTO paths (path, kind, first_seen_at, last_seen_at) "
            "VALUES ('legacy.py', 'file', 'old', 'old')"
        )
        conn.commit()
        conn.close()

        spy = RefreshSpy(fake)
        with mock.patch.object(cli, "refresh", spy), contextlib.redirect_stdout(io.StringIO()):
            code, err = self.run_main("list-types")

        self.assertEqual(code, 0)
        self.assertEqual(spy.calls, 1)
        self.assertIn("auto-refresh (first-run)", err)

    def test_auto_refreshes_when_config_content_changes(self) -> None:
        fake = self.fake_git()
        fake.files = ["a.py"]
        fake.head = "SAME_HEAD"
        spy = RefreshSpy(fake)
        with mock.patch.object(cli, "refresh", spy), contextlib.redirect_stdout(io.StringIO()):
            self.run_main("list-types")
            self.audit_config.write_text(
                CONFIG_TOML.replace('include = ["*.py"]', 'include = ["src/*.py"]'),
                encoding="utf-8",
            )
            code, err = self.run_main("list-types")

        self.assertEqual(code, 0)
        self.assertEqual(spy.calls, 2)
        self.assertIn("auto-refresh (config-changed)", err)

    def test_auto_refreshes_when_git_index_changes(self) -> None:
        fake = self.fake_git()
        fake.files = ["a.py"]
        fake.head = "SAME_HEAD"
        spy = RefreshSpy(fake)
        with mock.patch.object(cli, "refresh", spy), contextlib.redirect_stdout(io.StringIO()):
            self.run_main("list-types")
            support.write_file(self.repo / "staged.py")
            support.run_git(self.repo, "add", "staged.py")
            code, err = self.run_main("list-types")

        self.assertEqual(code, 0)
        self.assertEqual(spy.calls, 2)
        self.assertIn("auto-refresh (index-changed)", err)


class NotConfiguredTest(support.RepoTestCase):
    """No docs/work/audits/config.toml and no --config → exit 4, nothing made."""

    def assert_nothing_created(self) -> None:
        self.assertFalse((self.repo / "docs/work/audits").exists())
        self.assertFalse(self.cache.exists())

    def run_bare(self, *args: str) -> tuple[int, str]:
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = cli.main(list(args))
        return code, err.getvalue()

    # 6. list-types refuses with exit 4 and names the missing path ------------
    def test_list_types_not_configured_exits_4(self) -> None:
        code, err = self.run_bare("list-types")
        self.assertEqual(code, cli.EXIT_NOT_CONFIGURED)
        self.assertIn("not opted in", err)
        self.assertIn(str(default_config_path(self.repo)), err)
        self.assert_nothing_created()

    # 7. done refuses identically — no command bypasses the opt-in gate -------
    def test_done_refuses_identically_when_not_configured(self) -> None:
        code, err = self.run_bare("done", "a.py", "code-quality")
        self.assertEqual(code, cli.EXIT_NOT_CONFIGURED)
        self.assertIn("not opted in", err)
        self.assert_nothing_created()

    # 8. an explicit --config opts a repo in even without the default file ----
    def test_explicit_config_opts_in(self) -> None:
        # The opt-in path proceeds all the way to auto-refresh, which needs a
        # HEAD to compare against.
        support.run_git(
            self.repo,
            "-c",
            "user.email=test@example.com",
            "-c",
            "user.name=Test",
            "commit",
            "--allow-empty",
            "-m",
            "initial",
        )
        config = support.write_file(
            self.tmp / "elsewhere.toml",
            "[audit_types.code-quality]\n"
            'targets = [{ kind = "file", include = ["*.py"] }]\n',
        )
        err = io.StringIO()
        out = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
            code = cli.main(["--db", str(self.tmp / "x.db"), "--config", str(config), "list-types"])
        self.assertEqual(code, 0)

    def test_next_json_reports_not_configured_without_error(self) -> None:
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["next", "code-quality", "--format", "json"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out.getvalue()), {"outcome": "not-configured"})
        self.assertIn("not opted in", err.getvalue())
        self.assert_nothing_created()

    def test_next_json_rejects_unknown_type_even_when_unconfigured(self) -> None:
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["next", "typo", "--format", "json"])
        self.assertEqual(code, 2)
        self.assertEqual(out.getvalue(), "")
        self.assertIn("unknown shipped audit type", err.getvalue())
        self.assert_nothing_created()

    def test_validate_path_works_without_tracker_config_or_cache(self) -> None:
        support.write_file(self.repo / "app/main.py")
        support.run_git(self.repo, "add", "app/main.py")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = cli.main(
                ["validate-path", "./app/main.py", "code-quality", "--format", "json"]
            )
        self.assertEqual(code, 0)
        self.assertEqual(
            json.loads(out.getvalue()),
            {
                "outcome": "valid",
                "path": "app/main.py",
                "kind": "file",
                "audit_type": "code-quality",
                "configured": False,
            },
        )
        self.assertFalse(self.cache.exists())


class StructuredCliTest(CliTestBase):
    def setUp(self) -> None:
        super().setUp()
        support.write_file(self.repo / "target.py")
        support.run_git(self.repo, "add", "target.py")
        support.run_git(
            self.repo,
            "-c", "user.email=test@example.com",
            "-c", "user.name=Test",
            "commit", "-qm", "initial",
        )

    def run_captured(self, *args: str) -> tuple[int, str, str]:
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main([*self.cli_args, *args])
        return code, out.getvalue(), err.getvalue()

    def test_next_json_has_stable_machine_fields(self) -> None:
        code, out, _err = self.run_captured("next", "code-quality", "--format", "json")
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(payload["outcome"], "selected")
        self.assertEqual(payload["candidates"][0]["path"], "target.py")
        self.assertEqual(payload["candidates"][0]["reason"], "never-audited")

    def test_unknown_audit_type_is_an_error_not_empty(self) -> None:
        code, out, err = self.run_captured("next", "typo", "--format", "json")
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn("unknown audit type", err)

    def test_validate_path_canonicalizes_absolute_path(self) -> None:
        code, out, _err = self.run_captured(
            "validate-path",
            str((self.repo / "target.py").resolve()),
            "code-quality",
            "--format",
            "json",
        )
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(payload["path"], "target.py")
        self.assertTrue(payload["configured"])

    def test_next_never_selects_local_or_external_symlinks(self) -> None:
        outside = support.write_file(self.tmp / "outside.py")
        (self.repo / "local-link.py").symlink_to("target.py")
        (self.repo / "external-link.py").symlink_to(outside)
        support.run_git(self.repo, "add", "local-link.py", "external-link.py")

        code, out, _err = self.run_captured(
            "next", "code-quality", "-n", "10", "--format", "json"
        )
        self.assertEqual(code, 0)
        paths = {candidate["path"] for candidate in json.loads(out)["candidates"]}
        self.assertEqual(paths, {"target.py"})


if __name__ == "__main__":
    unittest.main()
