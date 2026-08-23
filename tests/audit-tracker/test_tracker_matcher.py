"""Tests for include/exclude glob matching.

Ported from pia-maker's ``test_matcher.py``; the matcher itself replaced
``PurePosixPath.full_match`` (3.13+) with a hand-rolled translation whose
semantics these tests pin — chiefly that ``**`` spans one or more whole
segments and never collapses to zero.
"""

import unittest

import support  # noqa: F401  (bootstrap: puts the skill package on sys.path)

from audit_tracker.config import ConfigError, TargetRule
from audit_tracker.matcher import matches_rule


class MatcherTest(unittest.TestCase):
    def make_rule(self, include: list[str], exclude: list[str] | None = None) -> TargetRule:
        return TargetRule(kind="file", include=include, exclude=exclude or [])

    # 1. simple include ------------------------------------------------------
    def test_simple_include(self) -> None:
        rule = self.make_rule(["app/**/*.py"])
        self.assertTrue(matches_rule("app/api/routes.py", rule))
        self.assertFalse(matches_rule("docs/README.md", rule))

    # 2. exclude takes precedence over include -------------------------------
    def test_exclude_takes_precedence(self) -> None:
        rule = self.make_rule(
            ["app/**/*.py"],
            exclude=["**/__pycache__/**", "app/frontend/**"],
        )
        self.assertFalse(matches_rule("app/__pycache__/x.py", rule))
        self.assertFalse(matches_rule("app/frontend/dist/x.py", rule))
        self.assertTrue(matches_rule("app/features/x.py", rule))

    # 3. `**` requires at least one whole segment: "app/**" is not "app" -----
    def test_double_star_matches_nested_directories(self) -> None:
        rule = TargetRule(kind="directory", include=["app/**"])
        self.assertTrue(matches_rule("app/features/suggestions", rule))
        self.assertFalse(matches_rule("app", rule))

    # 4. literal paths match exactly, never their descendants ----------------
    def test_literal_path_matches(self) -> None:
        rule = TargetRule(kind="directory", include=["scripts"])
        self.assertTrue(matches_rule("scripts", rule))
        self.assertFalse(matches_rule("scripts/deploy", rule))

    # 5. an empty include list is rejected at construction time --------------
    def test_empty_include_is_rejected_at_construction(self) -> None:
        with self.assertRaises(ConfigError):
            TargetRule(kind="file", include=[])


if __name__ == "__main__":
    unittest.main()
