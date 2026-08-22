"""End-to-end tests for the ``audit-and-fix`` selector — the real subprocess
path, against a stubbed ``python3`` on PATH.

Ported from pia-maker's ``TestEndToEnd``. The bug this selector prevents is
silent and self-confirming: tracker warnings hit stderr immediately while the
candidate reaches stdout only at completion, so a caller reading the stream
could report "no path to audit" while thousands are pending.

Two properties carry this module:

- **Completion is a property of the process, not of the reader.** The real
  ``subprocess`` machinery stays in the test: a shim ``python3`` is placed
  FIRST on PATH which runs a stub body only when its first argument ends in
  ``tracker.py`` (the selector's launcher) and execs the real interpreter for
  anything else. Replacing ``subprocess.run`` itself would assert the stub.
- **Only exit 0 with the tracker's own sentence means "empty".** Silence,
  malformed output, and non-zero exits land on non-zero exit codes — and the
  tracker's new "not opted in" exit (4) is translated into a success-shaped
  ``not-configured`` outcome instead of an error.
"""

from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import sys
import time
import unittest
from pathlib import Path
from textwrap import dedent
import support

from select_next import EXIT_MALFORMED_OUTPUT, EXIT_TRACKER_FAILED, repo_root

_SELECTOR = support.SKILL_DIR / "select_next.py"

_CANDIDATE = "app/api/routes.py\t[file]\tnever audited"
_WARNING = "audit_tracker: auto-refresh (head-changed)"


class SelectorEndToEndTest(support.RepoTestCase):
    """Each test gets a fresh repo (the process CWD), a fresh shim on PATH."""

    def setUp(self) -> None:
        super().setUp()
        # Resolve the REAL interpreter before the shim dir shadows "python3".
        self.bin_dir = self.tmp / "bin"
        self.bin_dir.mkdir()
        self.env = dict(os.environ)
        self.env["SELECTOR_TEST_REAL_PYTHON3"] = shutil.which("python3") or sys.executable
        self.env["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env['PATH']}"
        self.write_shim()

    def write_shim(self) -> None:
        """A ``python3`` stand-in: stub body for tracker.py, exec otherwise."""
        shim = self.bin_dir / "python3"
        shim.write_text(
            "#!/usr/bin/env bash\n"
            "set -u\n"
            'if [[ "${1##*/}" == "tracker.py" ]]; then\n'
            '  printf \'%s\\n\' "$@" > "${SELECTOR_TEST_ARGV_LOG:-/dev/null}"\n'
            '  pwd -P > "${SELECTOR_TEST_CWD_LOG:-/dev/null}"\n'
            '  if [[ -n "${SELECTOR_TEST_BODY:-}" ]]; then\n'
            '    eval "$SELECTOR_TEST_BODY"\n'
            "  fi\n"
            '  exit "${SELECTOR_TEST_EXIT:-0}"\n'
            "fi\n"
            'exec "$SELECTOR_TEST_REAL_PYTHON3" "$@"\n',
            encoding="utf-8",
        )
        shim.chmod(0o755)

    def stub_tracker(
        self,
        body: str,
        *,
        exit_code: int = 0,
        argv_log: Path | None = None,
        cwd_log: Path | None = None,
    ) -> None:
        """Configure what the shimmed tracker does and logs."""
        self.env["SELECTOR_TEST_BODY"] = dedent(body).strip("\n")
        if argv_log is not None:
            self.env["SELECTOR_TEST_ARGV_LOG"] = str(argv_log)
        if cwd_log is not None:
            self.env["SELECTOR_TEST_CWD_LOG"] = str(cwd_log)
        if exit_code:
            self.env["SELECTOR_TEST_EXIT"] = str(exit_code)

    def run_selector(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(_SELECTOR), *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )

    # 1. nothing on stdout until the child exits; then the eligible candidate -
    def test_emits_no_result_until_the_tracker_exits(self) -> None:
        """Warnings first, candidate a second later — and nothing in between.

        This is the regression boundary. An implementation that interpreted the
        stream as it arrived would have decided something during the sleep;
        this asserts the selector's stdout is still empty then, and that the
        candidate it finally prints is the eligible one.
        """
        started = self.tmp / "tracker-started"
        self.stub_tracker(
            f"""
            echo '{_WARNING}' >&2
            echo 'audit_tracker: skipping 20 orphan record(s)' >&2
            touch '{started}'
            sleep 1
            printf 'app/api/routes.py\\t[file]\\tnever audited\\n'
            """
        )

        proc = subprocess.Popen(
            [sys.executable, str(_SELECTOR), "code-quality"],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 30
            while not started.exists():
                assert proc.poll() is None, "the selector exited before the tracker ran"
                assert time.monotonic() < deadline, "the stubbed tracker never started"
                time.sleep(0.01)

            # Both warnings are now on the wire and the candidate is ~1s away.
            # Anything readable from the selector at this instant would be a
            # verdict formed from stderr.
            assert proc.stdout is not None
            ready, _, _ = select.select([proc.stdout], [], [], 0.4)
            self.assertEqual(ready, [], "the selector wrote output before the tracker finished")
            self.assertIsNone(proc.poll(), "the selector exited before the tracker finished")

            stdout, _stderr = proc.communicate(timeout=30)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()

        self.assertEqual(proc.returncode, 0)
        self.assertEqual(
            json.loads(stdout),
            {
                "outcome": "selected",
                "path": "app/api/routes.py",
                "kind": "file",
                "reason": "never audited",
                "diagnostics": [_WARNING, "audit_tracker: skipping 20 orphan record(s)"],
            },
        )

    # 2. the sentinel sentence → success-shaped empty outcome ------------------
    def test_explicit_no_candidates_response(self) -> None:
        self.stub_tracker(
            f"""
            echo '{_WARNING}' >&2
            echo "No candidates for 'doc-quality' under 'docs/work/kaizen'."
            """
        )
        result = self.run_selector("doc-quality", "--under", "docs/work/kaizen")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            json.loads(result.stdout),
            {"outcome": "empty", "diagnostics": [_WARNING]},
        )

    # 3. two records → exit 3 with no record on stdout -------------------------
    def test_malformed_success_output_exits_non_zero_with_no_record(self) -> None:
        self.stub_tracker(
            """
            printf 'app/api/routes.py\\t[file]\\tnever audited\\n'
            printf 'docs/README.md\\t[file]\\tnever audited\\n'
            """
        )
        result = self.run_selector("code-quality")
        self.assertEqual(result.returncode, EXIT_MALFORMED_OUTPUT)
        self.assertEqual(result.stdout.strip(), "")
        self.assertIn("got 2", result.stderr)

    # 4. silence is never an empty queue ----------------------------------------
    def test_silent_tracker_is_not_an_empty_queue(self) -> None:
        self.stub_tracker(f"echo '{_WARNING}' >&2")
        result = self.run_selector("code-quality")
        self.assertEqual(result.returncode, EXIT_MALFORMED_OUTPUT)
        self.assertEqual(result.stdout.strip(), "")
        self.assertIn(_WARNING, result.stderr)

    # 5. a failed tracker's status is reported, not swallowed -------------------
    def test_non_zero_tracker_exit_is_reported_not_swallowed(self) -> None:
        self.stub_tracker(
            """
            echo "audit_tracker: no such audit type 'nope'" >&2
            exit 2
            """,
            exit_code=2,
        )
        result = self.run_selector("nope")
        self.assertEqual(result.returncode, EXIT_TRACKER_FAILED)
        self.assertEqual(result.stdout.strip(), "")
        self.assertIn("exited 2", result.stderr)
        self.assertIn("no such audit type", result.stderr)

    # 6. tracker exit 4 → success-shaped not-configured outcome -----------------
    def test_not_configured_exit_is_translated_not_failed(self) -> None:
        """A repo that never opted in gets a distinct, honest answer: the
        selector exits 0 printing ``not-configured``, not an error and not
        ``empty``."""
        sentence = (
            "audit_tracker: not opted in — missing config: "
            "docs/work/audits/config.toml"
        )
        self.stub_tracker(f"echo '{sentence}' >&2", exit_code=4)
        result = self.run_selector("code-quality")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            json.loads(result.stdout),
            {"outcome": "not-configured", "diagnostics": [sentence]},
        )

    # 7. --kind/--under reach the launcher, run from the repo root --------------
    def test_kind_and_under_reach_the_tracker_from_the_repo_root(self) -> None:
        argv_log = self.tmp / "argv"
        cwd_log = self.tmp / "cwd"
        self.stub_tracker(
            """
            printf 'docs/architecture\\t[directory]\\tnever audited\\n'
            """,
            argv_log=argv_log,
            cwd_log=cwd_log,
        )
        result = self.run_selector("doc-quality", "--kind", "directory", "--under", "docs")

        self.assertEqual(result.returncode, 0)
        argv_lines = argv_log.read_text().splitlines()
        # First argument is the launcher path; it must be THIS skill's tracker.
        self.assertTrue(argv_lines[0].endswith("tracker.py"), argv_lines[0])
        self.assertEqual(argv_lines[1:], ["next", "doc-quality", "-n", "1",
                                          "--kind", "directory", "--under", "docs"])
        self.assertEqual(Path(cwd_log.read_text().strip()).resolve(), repo_root().resolve())
        self.assertEqual(json.loads(result.stdout)["path"], "docs/architecture")


if __name__ == "__main__":
    unittest.main()
