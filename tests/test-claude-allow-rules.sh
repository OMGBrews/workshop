#!/usr/bin/env bash
# Run the real Claude harness against a local CLI stub and isolated homes.
# Verify the seeded allow list uses bare tool names after setup and over old rules.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WORKSHOP_ROOT
python3 - <<'PY'
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BARE_RULES = ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "WebFetch", "WebSearch"]
OLD_RULES = [f"{tool}(*)" for tool in BARE_RULES]


class AllowRulesTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="claude-allow-rules-")
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name)
        self.settings = self.home / ".claude/settings.json"
        self.settings.parent.mkdir()
        binary = self.home / "bin/claude"
        binary.parent.mkdir()
        binary.write_text("#!/bin/sh\nprintf 'fixture Claude version\\n'\n")
        binary.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        HARNESS_MANIFEST=str(self.home / "manifest"),
                        PATH=str(binary.parent) + os.pathsep + os.environ["PATH"])

    def setup_harness(self):
        harness = Path(os.environ["WORKSHOP_ROOT"]) / "Tools/devcontainer/build/harness-claude.sh"
        result = subprocess.run(["bash", str(harness)], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(self.settings.read_text())

    def test_fresh_home_seeds_bare_rules(self):
        self.assertEqual(self.setup_harness()["permissions"]["allow"], BARE_RULES)

    def test_rerun_replaces_old_rules_and_keeps_unrelated_settings(self):
        self.settings.write_text(json.dumps({
            "model": "keep-model",
            "permissions": {"allow": OLD_RULES, "deny": []},
        }))
        result = self.setup_harness()
        self.assertEqual(result["permissions"]["allow"], BARE_RULES)
        self.assertEqual(result["model"], "keep-model")


unittest.main(verbosity=2)
PY
