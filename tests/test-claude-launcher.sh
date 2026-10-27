#!/usr/bin/env bash
# Exercise direct PATH launches against a local native-CLI recorder. These
# checks prove argument and settings preservation; live /context evidence is
# still required to establish how Claude loads the resulting exclusions.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WORKSHOP_ROOT
python3 - <<'PY'
import json
import fnmatch
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


RULES = {
    "signal-hygiene": "# Signal hygiene",
    "definition-of-done": "# Definition of done",
    "verification-terminology": "# Verification terminology",
}


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="claude-launcher-test-")
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.shim = self.base / "shim"
        self.alias = self.base / "alias"
        self.native = self.base / "native"
        for directory in (self.shim, self.alias, self.native):
            directory.mkdir()
        source = Path(os.environ["WORKSHOP_ROOT"]) / "Tools/devcontainer/build/claude-launcher.py"
        shutil.copyfile(source, self.shim / "claude")
        (self.shim / "claude").chmod(0o755)
        (self.alias / "claude").symlink_to(self.shim / "claude")
        recorder = self.native / "claude"
        recorder.write_text(
            "#!/usr/bin/env python3\nimport json, os, sys\n"
            "print(json.dumps({'args': sys.argv[1:], 'cwd': os.getcwd()}))\n"
            "sys.exit(int(os.environ.get('MOCK_CLAUDE_EXIT', '0')))\n"
        )
        recorder.chmod(0o755)
        self.env = dict(os.environ, PATH=os.pathsep.join(
            (str(self.shim), str(self.alias), str(self.native), os.environ["PATH"])))
        self.parent = self.repo(self.base / "parent", rules=True)
        self.child = self.repo(self.parent / "child", rules=True)

    def repo(self, path, rules=False):
        path.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "-q", str(path)], check=True)
        (path / "AGENTS.md").write_text("# Fixture\n\nRepository instructions.\n")
        if rules:
            for name, heading in RULES.items():
                docs = path / "workshop/docs"
                links = path / ".claude/rules"
                docs.mkdir(parents=True, exist_ok=True)
                links.mkdir(parents=True, exist_ok=True)
                (docs / (name + ".md")).write_text(heading + "\n\nFixture rule.\n")
                (links / (name + ".md")).symlink_to("../../workshop/docs/" + name + ".md")
        return path

    def run_cli(self, *args, cwd=None, env=None, ok=True):
        result = subprocess.run(["claude", *args], cwd=cwd or self.child,
                                env=env or self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        return result

    def settings_and_args(self, result):
        args = result["args"]
        self.assertEqual(args[0], "--settings")
        return json.loads(args[1]), args[2:]

    def expected(self, root, names=RULES):
        return {str(root / ".claude/rules" / (name + ".md")) for name in names}

    def test_direct_launch_excludes_ancestor_links_and_preserves_own_rules(self):
        settings, rest = self.settings_and_args(self.run_cli("-p", "/context"))
        self.assertEqual(set(settings["claudeMdExcludes"]), self.expected(self.parent))
        self.assertTrue(self.expected(self.child).isdisjoint(settings["claudeMdExcludes"]))
        self.assertEqual(rest, ["-p", "/context"])

    def test_parent_root_and_standalone_child_have_no_generated_settings(self):
        self.assertEqual(self.run_cli("-p", "/context", cwd=self.parent)["args"], ["-p", "/context"])
        standalone = self.repo(self.base / "standalone", rules=True)
        self.assertEqual(self.run_cli("-p", "/context", cwd=standalone)["args"], ["-p", "/context"])

    def test_clean_library_keeps_all_inherited_rules(self):
        library = self.repo(self.child / "library")
        self.assertEqual(self.run_cli("-p", "/context", cwd=library)["args"], ["-p", "/context"])

    def test_deeper_nesting_excludes_each_ancestor_and_launch_subdirectory_works(self):
        package = self.repo(self.child / "Packages/shared", rules=True)
        subdir = package / "src"
        subdir.mkdir()
        settings, _ = self.settings_and_args(self.run_cli(cwd=subdir))
        self.assertEqual(set(settings["claudeMdExcludes"]),
                         self.expected(self.parent) | self.expected(self.child))

    def test_partial_own_rules_only_replace_available_rules(self):
        (self.child / ".claude/rules/signal-hygiene.md").unlink()
        (self.child / ".claude/rules/definition-of-done.md").unlink()
        settings, _ = self.settings_and_args(self.run_cli())
        self.assertEqual(set(settings["claudeMdExcludes"]),
                         self.expected(self.parent, ["verification-terminology"]))

    def test_glob_metacharacters_are_literal_in_ancestor_paths(self):
        parent = self.repo(self.base / "parent[1]*{a,b}(x)?", rules=True)
        child = self.repo(parent / "child", rules=True)
        settings, _ = self.settings_and_args(self.run_cli(cwd=child))
        patterns = settings["claudeMdExcludes"]
        for path in self.expected(parent):
            self.assertTrue(any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns))
            other = path.replace("parent[1]*{a,b}(x)?", "parent1-any-a-x0")
            self.assertFalse(any(fnmatch.fnmatchcase(other, pattern) for pattern in patterns))

    def test_unrelated_ancestor_topics_and_same_basename_real_files_are_retained(self):
        topic = self.parent / ".claude/rules/cloud-sessions.md"
        topic.write_text("# Cloud instructions\n\nKeep these.\n")
        same_name = self.parent / ".claude/rules/definition-of-done.md"
        same_name.unlink()
        same_name.write_text("# Definition of done\n\nLocal topic, not a Workshop link.\n")
        arbitrary = self.parent / ".claude/rules/signal-hygiene.md"
        arbitrary.unlink()
        arbitrary.symlink_to("../../AGENTS.md")
        settings, _ = self.settings_and_args(self.run_cli())
        self.assertEqual(set(settings["claudeMdExcludes"]),
                         self.expected(self.parent, ["verification-terminology"]))

    def test_caller_inline_settings_and_exclusions_survive(self):
        custom = {"model": "keep-model", "permissions": {"deny": ["Bash(rm *)"]},
                  "claudeMdExcludes": ["/manual/CLAUDE.md"]}
        settings, rest = self.settings_and_args(self.run_cli(
            "--settings", json.dumps(custom), "-p", "/context"))
        self.assertEqual(settings["model"], custom["model"])
        self.assertEqual(settings["permissions"], custom["permissions"])
        self.assertIn("/manual/CLAUDE.md", settings["claudeMdExcludes"])
        self.assertEqual(len(settings["claudeMdExcludes"]), 4)
        self.assertEqual(rest, ["-p", "/context"])

    def test_file_settings_and_last_settings_value_survive_without_file_changes(self):
        config = self.child / "custom-settings.json"
        content = '{"model":"keep-file-model","hooks":{"SessionStart":[]}}\n'
        config.write_text(content)
        settings, rest = self.settings_and_args(self.run_cli(
            "--settings", '{"model":"discard-earlier"}', "--settings=custom-settings.json", "prompt"))
        self.assertEqual(settings["model"], "keep-file-model")
        self.assertEqual(settings["hooks"], {"SessionStart": []})
        self.assertEqual(rest, ["prompt"])
        self.assertEqual(config.read_text(), content)

    def test_positional_separator_retains_prompt_looking_like_flags(self):
        settings, rest = self.settings_and_args(self.run_cli("--", "--settings", "prompt"))
        self.assertEqual(set(settings["claudeMdExcludes"]), self.expected(self.parent))
        self.assertEqual(rest, ["--", "--settings", "prompt"])
        for prompt in ("--help", "--version", "--bare", "--cloud"):
            with self.subTest(prompt=prompt):
                _, rest = self.settings_and_args(self.run_cli("--", prompt))
                self.assertEqual(rest, ["--", prompt])

    def test_native_workshop_links_and_wrong_heading_are_distinguished(self):
        native_workshop = self.repo(self.parent / "public-workshop")
        (native_workshop / "docs").mkdir()
        (native_workshop / ".claude/rules").mkdir(parents=True)
        for name, heading in RULES.items():
            (native_workshop / "docs" / (name + ".md")).write_text(heading + "\n")
            (native_workshop / ".claude/rules" / (name + ".md")).symlink_to("../../docs/" + name + ".md")
        (native_workshop / "docs/signal-hygiene.md").write_text("# Different topic\n")
        settings, _ = self.settings_and_args(self.run_cli(cwd=native_workshop))
        self.assertEqual(set(settings["claudeMdExcludes"]),
                         self.expected(self.parent, ["definition-of-done", "verification-terminology"]))

    def test_malformed_settings_fail_instead_of_silently_losing_user_configuration(self):
        for args in (("--settings", "{"), ("--settings",),
                     ("--settings", '{"claudeMdExcludes":"invalid"}')):
            with self.subTest(args=args):
                result = self.run_cli(*args, ok=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("claude launcher:", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_maintenance_and_disabled_customization_modes_pass_through(self):
        for args in (("update",), ("auth", "status"), ("--version",),
                     ("--help",), ("--bare", "-p", "prompt"), ("--safe-mode",),
                     ("--cloud", "prompt"), ("remote-control",),
                     ("--cloud=prompt",), ("--environment=runner",),
                     ("--desktop=prompt",), ("--teleport=session",)):
            with self.subTest(args=args):
                self.assertEqual(self.run_cli(*args)["args"], list(args))

    def test_user_settings_and_all_rule_symlinks_remain_unchanged(self):
        config = self.child / ".claude/settings.local.json"
        config.write_text('{"model":"local-model","claudeMdExcludes":["/manual"]}\n')
        before = self.snapshot()
        self.run_cli("-p", "/context")
        self.assertEqual(self.snapshot(), before)

    def snapshot(self):
        result = {}
        for path in self.parent.rglob("*"):
            if ".git" in path.relative_to(self.parent).parts:
                continue
            if path.is_symlink():
                result[str(path)] = ("link", os.readlink(path))
            elif path.is_file():
                result[str(path)] = ("file", path.read_bytes())
        return result

    def test_native_exit_status_is_preserved(self):
        result = self.run_cli("-p", "prompt", env=dict(self.env, MOCK_CLAUDE_EXIT="17"), ok=False)
        self.assertEqual(result.returncode, 17)

    def test_symlink_alias_launch_skips_every_copy_of_the_shim_on_path(self):
        env = dict(self.env, PATH=os.pathsep.join(
            (str(self.alias), str(self.shim), str(self.native), os.environ["PATH"])))
        settings, _ = self.settings_and_args(self.run_cli(env=env))
        self.assertEqual(set(settings["claudeMdExcludes"]), self.expected(self.parent))

    def test_missing_native_cli_fails_without_recursion(self):
        env = dict(self.env, PATH=os.pathsep.join((str(self.shim), str(self.alias), "/usr/bin", "/bin")))
        result = self.run_cli(env=env, ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native claude executable missing", result.stderr)

    def test_harness_setup_rejects_a_shim_without_native_cli(self):
        home = self.base / "home"
        home.mkdir()
        env = dict(self.env, HOME=str(home), PATH=os.pathsep.join(
            (str(self.shim), str(self.alias), "/usr/bin", "/bin")))
        harness = Path(os.environ["WORKSHOP_ROOT"]) / "Tools/devcontainer/build/harness-claude.sh"
        result = subprocess.run(["bash", str(harness)], env=env,
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native claude executable missing", result.stderr)
        self.assertFalse((home / ".devcontainer-harnesses").exists())

    def test_non_repository_launch_is_unchanged(self):
        self.assertEqual(self.run_cli("-p", "prompt", cwd=self.base)["args"], ["-p", "prompt"])


unittest.main(verbosity=2)
PY
