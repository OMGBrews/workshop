"""Tests for the audit tracker's TOML config loader.

Ported from pia-maker's ``test_config.py`` and adapted to the new contract:
the config is consumer-repo TOML (``docs/work/audits/config.toml``) whose
presence *is* the opt-in signal — there is no packaged default to load any
more, so the "default config" tests pin the path and the not-opted-in error
instead. The prompt vocabulary checks are new: a config may only select among
the shipped prompt files.
"""


import support

import tempfile
import unittest
from pathlib import Path

from audit_tracker import config as config_mod
from audit_tracker.config import (
    CONFIG_SUBPATH,
    ConfigError,
    TargetRule,
    default_config_path,
    load_config,
    parse_config,
    validate_types_have_prompts,
)


CODE_QUALITY_TOML = """
[audit_types.my-audit]
description = "example"
targets = [{ kind = "file", include = ["**/*.md"] }]
"""


def write_toml(directory: Path, body: str) -> Path:
    toml_path = directory / "audits.toml"
    toml_path.write_text(body.strip() + "\n", encoding="utf-8")
    return toml_path


class LoadConfigTest(support.RepoTestCase):
    # 1. an explicitly named TOML file loads into the new dataclasses --------
    def test_load_config_from_explicit_path(self) -> None:
        toml_path = write_toml(self.tmp, CODE_QUALITY_TOML)
        loaded = load_config(toml_path)
        audit = loaded.audit_types["my-audit"]
        self.assertEqual(audit.description, "example")
        self.assertEqual(len(audit.targets), 1)
        rule = audit.targets[0]
        self.assertEqual(rule.kind, "file")
        self.assertEqual(rule.include, ["**/*.md"])

    # 2. an unknown target kind is rejected ----------------------------------
    def test_invalid_kind_is_rejected(self) -> None:
        toml_path = write_toml(
            self.tmp,
            """
            [audit_types.bad]
            targets = [{ kind = "folder", include = ["*.md"] }]
            """,
        )
        with self.assertRaises(ConfigError) as caught:
            load_config(toml_path)
        self.assertIn("kind", str(caught.exception))

    # 3. unknown keys are rejected, at the top level and per type ------------
    def test_unknown_top_level_key_is_rejected(self) -> None:
        toml_path = write_toml(
            self.tmp,
            """
            typo = true
            [audit_types.ok]
            targets = [{ kind = "file", include = ["*.py"] }]
            """,
        )
        with self.assertRaises(ConfigError) as caught:
            load_config(toml_path)
        self.assertIn("unknown top-level keys: typo", str(caught.exception))

    def test_unknown_type_keys_are_rejected(self) -> None:
        toml_path = write_toml(
            self.tmp,
            """
            [audit_types.bad]
            descripton = "typo'd key"
            targets = [{ kind = "file", include = ["*.py"] }]
            """,
        )
        with self.assertRaises(ConfigError) as caught:
            load_config(toml_path)
        self.assertIn("unknown keys: descripton", str(caught.exception))

    def test_unknown_rule_keys_are_rejected(self) -> None:
        toml_path = write_toml(
            self.tmp,
            """
            [audit_types.bad]
            targets = [{ kind = "file", include = ["*.py"], negated = true }]
            """,
        )
        with self.assertRaises(ConfigError) as caught:
            load_config(toml_path)
        self.assertIn("unknown keys: negated", str(caught.exception))

    # 4. every problem is collected into ONE message, not raised one at a time
    def test_all_errors_are_collected_into_one_message(self) -> None:
        toml_path = write_toml(
            self.tmp,
            """
            [audit_types.first]
            targets = [{ kind = "folder", include = ["*.md"] }]

            [audit_types.second]
            targets = []
            """,
        )
        with self.assertRaises(ConfigError) as caught:
            load_config(toml_path)
        message = str(caught.exception)
        # Both problems are named, joined into a single loud failure.
        self.assertIn("folder", message)
        self.assertIn("non-empty", message)
        self.assertIn("; ", message)

    # 5. empty include lists are rejected ------------------------------------
    def test_empty_include_is_rejected(self) -> None:
        toml_path = write_toml(
            self.tmp,
            """
            [audit_types.bad]
            targets = [{ kind = "file", include = [] }]
            """,
        )
        with self.assertRaises(ConfigError) as caught:
            load_config(toml_path)
        self.assertIn("include", str(caught.exception))
        with self.assertRaises(ConfigError):
            TargetRule(kind="file", include=[])

    # 6. non-string patterns are rejected ------------------------------------
    def test_non_string_pattern_is_rejected(self) -> None:
        with self.assertRaises(ConfigError):
            TargetRule(kind="file", include=["*.py"], exclude=[3])  # type: ignore[list-item]

    # 7. a type with no targets, and an empty type table, are rejected -------
    def test_audit_type_without_targets_is_rejected(self) -> None:
        with self.assertRaises(ConfigError):
            parse_config({"audit_types": {"bad": {"description": "x"}}}, "<test>")

    def test_config_without_audit_types_is_rejected(self) -> None:
        with self.assertRaises(ConfigError):
            parse_config({"audit_types": {}}, "<test>")

    # 8. malformed TOML and missing files surface as ConfigError -------------
    def test_malformed_toml_raises_config_error(self) -> None:
        toml_path = write_toml(self.tmp, "[audit_types\nbroken ==")
        with self.assertRaises(ConfigError) as caught:
            load_config(toml_path)
        self.assertIn("not valid TOML", str(caught.exception))

    def test_missing_file_raises_config_error(self) -> None:
        with self.assertRaises(ConfigError) as caught:
            load_config(self.tmp / "nope.toml")
        self.assertIn("not found", str(caught.exception))


class DefaultPathTest(support.RepoTestCase):
    # 9. the default path is the consumer repo's opt-in TOML -----------------
    def test_default_config_path_points_to_consumer_toml(self) -> None:
        expected = self.repo / CONFIG_SUBPATH
        self.assertEqual(default_config_path(self.repo), expected)
        self.assertEqual(CONFIG_SUBPATH, "docs/work/audits/config.toml")
        # With no repo argument it resolves from the process CWD.
        self.assertEqual(default_config_path(), expected)


class ValidatePromptsTest(support.RepoTestCase):
    """A config may only select among the shipped prompt vocabulary."""

    def make_config_with(self, kinds: list[str]) -> object:
        return parse_config(
            {
                "audit_types": {
                    "code-quality": {
                        "targets": [{"kind": kind, "include": ["**"]} for kind in kinds]
                    }
                }
            },
            "<test>",
        )

    # 10. against a temp prompts dir: present combos pass --------------------
    def test_present_combinations_pass_against_temp_prompts_dir(self) -> None:
        with tempfile.TemporaryDirectory() as prompts:
            Path(prompts, "code-quality-file.md").write_text("p", encoding="utf-8")
            Path(prompts, "code-quality-directory.md").write_text("p", encoding="utf-8")
            validate_types_have_prompts(self.make_config_with(["file", "directory"]), Path(prompts))

    # 11. against a temp prompts dir: a missing combo is named ---------------
    def test_missing_combination_is_named(self) -> None:
        with tempfile.TemporaryDirectory() as prompts:
            Path(prompts, "code-quality-file.md").write_text("p", encoding="utf-8")
            with self.assertRaises(ConfigError) as caught:
                validate_types_have_prompts(
                    self.make_config_with(["file", "directory"]), Path(prompts)
                )
            self.assertIn("code-quality-directory", str(caught.exception))

    # 12. against the real shipped prompts dir: the shipped types validate ---
    def test_shipped_types_validate_against_real_prompts_dir(self) -> None:
        prompts_dir = support.SKILL_DIR / "prompts"
        loaded = load_config(
            write_toml(
                self.tmp,
                """
                [audit_types.code-quality]
                targets = [
                  { kind = "file", include = ["**/*.py"] },
                  { kind = "directory", include = ["app"] },
                ]

                [audit_types.readme-quality]
                targets = [{ kind = "directory", include = ["docs"] }]
                """,
            )
        )
        validate_types_have_prompts(loaded, prompts_dir)

    # 13. ...while an invented type does not ---------------------------------
    def test_invented_type_fails_against_real_prompts_dir(self) -> None:
        prompts_dir = support.SKILL_DIR / "prompts"
        invented = parse_config(
            {
                "audit_types": {
                    "prose-quality": {"targets": [{"kind": "file", "include": ["**"]}]}
                }
            },
            "<test>",
        )
        with self.assertRaises(ConfigError) as caught:
            validate_types_have_prompts(invented, prompts_dir)
        self.assertIn("prose-quality-file", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
