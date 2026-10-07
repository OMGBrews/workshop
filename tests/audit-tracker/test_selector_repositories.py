"""End-to-end tests for the selector against the REAL tracker and a real
nested repository.

``test_selector_endtoend`` proves the selector's completion and exit-status
discipline against a stubbed tracker. This module removes the stub: the
selector runs as a subprocess from the control root and spawns the real
launcher, so the repository identity it reports and the failures it refuses
to turn into an empty queue are the tracker's own.
"""

from __future__ import annotations

import json
import subprocess
import sys
import unittest

import support
from test_tracker_repositories import SubjectRepositoryTestCase, git

from select_next import EXIT_TRACKER_FAILED

_SELECTOR = support.SKILL_DIR / "select_next.py"


class SelectorRepositoryTest(SubjectRepositoryTestCase):
    def select(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(_SELECTOR), "code-quality", *args],
            cwd=self.repo,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )

    def test_selects_from_the_subject_with_its_identity(self) -> None:
        result = self.select("--repository", "library", "--kind", "file", "--under", "src")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            {k: payload[k] for k in ("outcome", "repository", "path", "kind", "reason")},
            {
                "outcome": "selected",
                "repository": "library",
                "path": "src/core.py",
                "kind": "file",
                "reason": "never-audited",
            },
        )

    def test_unscoped_selection_carries_a_repository(self) -> None:
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn(payload["repository"], {"self", "library"})
        candidates = {("self", "tool.py"), ("library", "tool.py"), ("library", "src/core.py"), ("library", "src")}
        self.assertIn((payload["repository"], payload["path"]), candidates)

    def test_control_scope_never_offers_subject_paths(self) -> None:
        result = self.select("--repository", "self")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual((payload["repository"], payload["path"]), ("self", "tool.py"))

    def test_recorded_subject_paths_leave_the_queue(self) -> None:
        for path in ("tool.py", "src/core.py", "src"):
            code, _out, err = self.run_cli("done", path, "code-quality", "--repository", "library")
            self.assertEqual(code, 0, err)
        result = self.select("--repository", "library")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        # Everything is audited and clean: the oldest audit comes back first,
        # never an empty queue that pretends nothing exists.
        self.assertEqual(payload["reason"], "clean")
        self.assertEqual(payload["repository"], "library")

    def test_a_broken_subject_is_a_failure_not_an_empty_queue(self) -> None:
        git(self.repo, "submodule", "deinit", "-q", "-f", "library")
        for scope in ((), ("--repository", "library")):
            with self.subTest(scope=scope):
                result = self.select(*scope)
                self.assertEqual(result.returncode, EXIT_TRACKER_FAILED)
                self.assertEqual(result.stdout, "")
                self.assertIn("is not a Git worktree root", result.stderr)
        result = self.select("--repository", "self")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["repository"], "self")

    def test_under_without_repository_is_a_failure(self) -> None:
        result = self.select("--under", "src")
        self.assertEqual(result.returncode, EXIT_TRACKER_FAILED)
        self.assertEqual(result.stdout, "")
        self.assertIn("--under needs --repository", result.stderr)


if __name__ == "__main__":
    unittest.main()
