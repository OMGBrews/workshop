#!/usr/bin/env bash
# Run the real Claude harness against a local CLI stub and isolated homes.
# Verify settings after setup and reruns, without a network install.
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


class AttributionDefaultsTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="claude-attribution-defaults-")
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
        self.assertIn("claude", (self.home / "manifest").read_text().splitlines())
        return json.loads(self.settings.read_text())

    def test_fresh_home_and_repeat_seed_both_empty_fields(self):
        first = self.setup_harness()
        self.assertEqual(first["attribution"], {"commit": "", "pr": ""})
        self.assertEqual(self.setup_harness(), first)

    def test_existing_unrelated_settings_survive_missing_attribution(self):
        self.settings.write_text(json.dumps({"model": "keep-model", "custom": {"keep": [1, 2]}}))
        result = self.setup_harness()
        self.assertEqual(result["attribution"], {"commit": "", "pr": ""})
        self.assertEqual(result["model"], "keep-model")
        self.assertEqual(result["custom"], {"keep": [1, 2]})

    def test_partial_and_explicit_preferences_survive_reruns(self):
        cases = [
            ({"commit": "Custom commit credit"}, {"commit": "Custom commit credit", "pr": ""}),
            ({"pr": "Custom PR credit"}, {"commit": "", "pr": "Custom PR credit"}),
            ({"commit": "", "pr": ""}, {"commit": "", "pr": ""}),
            ({"commit": "Custom", "pr": "Other", "extra": "keep"},
             {"commit": "Custom", "pr": "Other", "extra": "keep"}),
            ({"commit": None, "pr": "Custom"}, {"commit": None, "pr": "Custom"}),
        ]
        for existing, expected in cases:
            with self.subTest(existing=existing):
                self.settings.write_text(json.dumps({"attribution": existing, "model": "keep-model"}))
                first = self.setup_harness()
                self.assertEqual(first["attribution"], expected)
                self.assertEqual(first["model"], "keep-model")
                self.assertEqual(self.setup_harness(), first)


unittest.main(verbosity=2)
PY
