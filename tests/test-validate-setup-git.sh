#!/usr/bin/env bash
# Exercise the complete validator with real Git configuration scopes. An empty
# fixture manifest isolates neutral checks from harness installation.
set -euo pipefail
WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WORKSHOP_ROOT
python3 - <<'PY'
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class GlobalGitValidationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="validate-global-git-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.xdg = self.home / ".config/git/config"
        self.xdg.parent.mkdir(parents=True)
        self.xdg.touch()
        self.host = self.home / ".gitconfig"
        self.host.touch()
        self.repo = self.root / "repo"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_")}
        self.env.update(HOME=str(self.home),
                        XDG_CONFIG_HOME=str(self.home / ".config"),
                        GIT_CONFIG_NOSYSTEM="1",
                        HARNESS_MANIFEST=str(self.root / "manifest"))
        (self.root / "manifest").touch()
        subprocess.run(["git", "init", "--quiet", str(self.repo)],
                       env=self.env, check=True)
        self.filters = {"filter.lfs.clean": "git-lfs clean -- %f",
                        "filter.lfs.smudge": "git-lfs smudge -- %f",
                        "filter.lfs.process": "git-lfs filter-process"}
        self.config(self.host, "user.name", "Host Identity")
        self.config(self.host, "user.email", "host@example.invalid")
        for key, value in self.filters.items():
            self.config(self.xdg, key, value)

    def config(self, file, key, value):
        subprocess.run(["git", "config", "--file", str(file), key, value],
                       env=self.env, check=True)

    def validate(self, expected):
        script = Path(os.environ["WORKSHOP_ROOT"]) / "Tools/devcontainer/validate_setup.sh"
        result = subprocess.run(["bash", str(script)], cwd=self.repo,
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def test_host_identity_file_preserves_xdg_filters(self):
        self.assertIn("All setup checks passed", self.validate(0))

    def test_global_precedence_ignores_local_identity(self):
        self.config(self.xdg, "user.name", "XDG Identity")
        self.config(self.xdg, "user.email", "xdg@example.invalid")
        self.config(self.repo / ".git/config", "user.email", "local@example.invalid")
        self.assertIn("global scope (host@example.invalid)", self.validate(0))

    def test_local_filters_cannot_replace_missing_global_filters(self):
        self.xdg.write_text("")
        for key, value in self.filters.items():
            self.config(self.repo / ".git/config", key, value)
        output = self.validate(1)
        for name in ("clean", "smudge", "process"):
            self.assertIn("FAIL: Git LFS " + name + " filter", output)

    def test_local_identity_cannot_replace_missing_global_identity(self):
        self.host.write_text("")
        self.config(self.repo / ".git/config", "user.name", "Local Identity")
        self.config(self.repo / ".git/config", "user.email", "local@example.invalid")
        output = self.validate(1)
        self.assertIn("FAIL: no git user.name/user.email in global scope", output)
        self.assertIn("OK: Git LFS clean filter", output)

    def test_local_multiline_values_cannot_forge_global_scope(self):
        self.xdg.write_text("")
        for key in self.filters:
            self.config(self.repo / ".git/config", key, "local value\nglobal\tforged")
        output = self.validate(1)
        for name in ("clean", "smudge", "process"):
            self.assertIn("FAIL: Git LFS " + name + " filter", output)

    def test_explicit_global_file_override_is_respected(self):
        override = self.root / "override"
        override.write_text(self.host.read_text())
        self.env["GIT_CONFIG_GLOBAL"] = str(override)
        self.assertIn("FAIL: Git LFS clean filter", self.validate(1))


unittest.main(verbosity=2)
PY
