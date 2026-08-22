"""Validation matrix for ``select_next.interpret`` — over a run that has
already completed.

Ported from pia-maker's ``TestInterpret`` plus the new not-configured branch:
the tracker's dedicated exit 4 must translate into a success-shaped
``not-configured`` result *before* the nonzero-failure branch can see it.
"""


import support

import unittest

from select_next import (
    EXIT_MALFORMED_OUTPUT,
    EXIT_TRACKER_FAILED,
    SelectorError,
    TrackerRun,
    interpret,
)


# One real candidate line, exactly as the tracker's ``next`` renders it.
_CANDIDATE = "app/api/routes.py\t[file]\tnever audited"
_WARNING = "audit_tracker: auto-refresh (head-changed)"


class InterpretTest(unittest.TestCase):
    # 1. a well-shaped line becomes a selected record --------------------------
    def test_valid_candidate_becomes_a_selected_result(self) -> None:
        result = interpret(TrackerRun(0, _CANDIDATE + "\n", ""))
        self.assertEqual(
            result,
            {
                "outcome": "selected",
                "path": "app/api/routes.py",
                "kind": "file",
                "reason": "never audited",
                "diagnostics": [],
            },
        )

    # 2. a directory candidate keeps its kind ----------------------------------
    def test_directory_candidate_keeps_its_kind(self) -> None:
        line = "docs/architecture\t[directory]\t3 commit(s) since audit at 2026-08-01\n"
        result = interpret(TrackerRun(0, line, ""))
        self.assertEqual(
            result,
            {
                "outcome": "selected",
                "path": "docs/architecture",
                "kind": "directory",
                "reason": "3 commit(s) since audit at 2026-08-01",
                "diagnostics": [],
            },
        )

    # 3. only the tracker's own sentence means "empty" -------------------------
    def test_the_trackers_own_sentence_is_the_only_empty_result(self) -> None:
        for sentence in [
            "No candidates for 'code-quality'.",
            "No candidates for 'doc-quality' under 'docs/work/kaizen'.",
            'No candidates for "it\'s-odd".',
        ]:
            with self.subTest(sentence=sentence):
                self.assertEqual(
                    interpret(TrackerRun(0, sentence + "\n", "")),
                    {"outcome": "empty", "diagnostics": []},
                )

    # 4. stderr warnings survive as diagnostics on a selection -----------------
    def test_stderr_warnings_survive_as_diagnostics_on_a_selection(self) -> None:
        stderr = f"{_WARNING}\naudit_tracker: skipping 20 orphan record(s)\n"
        result = interpret(TrackerRun(0, _CANDIDATE + "\n", stderr))
        self.assertEqual(
            result["diagnostics"], [_WARNING, "audit_tracker: skipping 20 orphan record(s)"]
        )
        self.assertEqual(result["outcome"], "selected")

    # 5. warnings can never become the selected path ---------------------------
    def test_stderr_warnings_never_become_the_selected_path(self) -> None:
        # The original misread in one line: a warning arrives first, so a
        # stream-reading caller treats it as the record. Here it can only ever
        # reach `diagnostics`.
        result = interpret(TrackerRun(0, _CANDIDATE + "\n", _WARNING + "\n"))
        self.assertEqual(result["outcome"], "selected")
        self.assertEqual(result["path"], "app/api/routes.py")

    # 6. warnings alone are not proof of an empty queue -------------------------
    def test_warnings_alone_are_not_proof_of_an_empty_queue(self) -> None:
        # Nothing on stdout: the tracker has told us nothing at all. The one
        # answer that must be unreachable here is `empty`.
        with self.assertRaises(SelectorError) as caught:
            interpret(TrackerRun(0, "", _WARNING + "\n"))
        self.assertEqual(caught.exception.exit_code, EXIT_MALFORMED_OUTPUT)
        self.assertEqual(caught.exception.diagnostics, [_WARNING])

    # 7. exit status is checked before stdout -----------------------------------
    def test_exit_status_is_checked_before_stdout(self) -> None:
        # A perfectly-shaped candidate on the stdout of a tracker that died is
        # still not a selection.
        with self.assertRaises(SelectorError) as caught:
            interpret(TrackerRun(2, _CANDIDATE + "\n", _WARNING + "\n"))
        self.assertEqual(caught.exception.exit_code, EXIT_TRACKER_FAILED)
        self.assertEqual(caught.exception.diagnostics, [_WARNING])

    # 8. exit 4 is interpreted into not-configured before the failure branch ---
    def test_not_configured_exit_becomes_success_shaped_result(self) -> None:
        stderr = "audit_tracker: not opted in — missing config: docs/work/audits/config.toml"
        result = interpret(TrackerRun(4, "", stderr))
        self.assertEqual(
            result,
            {
                "outcome": "not-configured",
                "diagnostics": [stderr],
            },
        )

    # 9. every other success-output shape is rejected ---------------------------
    def test_malformed_success_output_is_rejected(self) -> None:
        cases = [
            ("", "silence"),
            (f"{_CANDIDATE}\ndocs/README.md\t[file]\tnever audited\n", "two records"),
            ("app/api/routes.py\tnever audited\n", "no kind field"),
            ("app/api/routes.py\t[symlink]\tnever audited\n", "unknown kind"),
            ("\t[file]\tnever audited\n", "empty path"),
            ("app/api/routes.py\t[file]\t\n", "empty reason"),
            ("There is nothing left to audit.\n", "prose that is not the sentinel"),
            ("No candidates for 'code-quality'. Try --stale.\n", "sentinel with a tail"),
        ]
        for stdout, why in cases:
            with self.subTest(stdout=stdout, why=why):
                with self.assertRaises(SelectorError) as caught:
                    interpret(TrackerRun(0, stdout, ""))
                self.assertEqual(caught.exception.exit_code, EXIT_MALFORMED_OUTPUT, why)


if __name__ == "__main__":
    unittest.main()
