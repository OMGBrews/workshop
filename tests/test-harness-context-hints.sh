#!/usr/bin/env bash
# Exercise legacy hint lookups in fresh shells, separately from classification.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import unittest


detector = Path(sys.argv.pop()).resolve() / "docs/templates/cloud-sessions/harness-signals.sh"


class ContextHintTests(unittest.TestCase):
    def run_shell(self, body, values=None):
        result = subprocess.run(
            ["bash", "-c", 'set -eu\n. "$DETECTOR"\n' + body],
            env={"PATH": os.environ["PATH"], "DETECTOR": str(detector), **(values or {})},
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def test_remote_hint_resolves_mutations_after_source(self):
        output = self.run_shell('''
harness_remote
CLAUDE_CODE_REMOTE=true
harness_remote
AGENT_SESSION_REMOTE=false
harness_remote
AGENT_SESSION_REMOTE=true CLAUDE_CODE_REMOTE=false
harness_remote
AGENT_SESSION_REMOTE=unknown CLAUDE_CODE_REMOTE=true
harness_remote
AGENT_SESSION_REMOTE= CLAUDE_CODE_REMOTE=false
harness_remote
unset AGENT_SESSION_REMOTE CLAUDE_CODE_REMOTE
harness_remote
''')
        self.assertEqual(output, "\ntrue\nfalse\ntrue\ntrue\nfalse\n\n")

    def test_shell_hint_preserves_neutral_precedence_and_empty_fallback(self):
        output = self.run_shell('''
harness_agent_shell
CLAUDECODE=1
harness_agent_shell
AGENT_SHELL=0
harness_agent_shell
AGENT_SHELL=1 CLAUDECODE=0
harness_agent_shell
AGENT_SHELL=
harness_agent_shell
unset AGENT_SHELL
CLAUDECODE=1
harness_agent_shell
unset CLAUDECODE
harness_agent_shell
''')
        self.assertEqual(output, "\n1\n0\n1\n0\n1\n\n")

    def test_project_hint_uses_current_literal_paths(self):
        output = self.run_shell('''
harness_project_dir
CLAUDE_PROJECT_DIR='/vendor project/[one]*'
harness_project_dir
AGENT_PROJECT_DIR='/neutral project/[two]*'
harness_project_dir
CLAUDE_PROJECT_DIR='/changed vendor project'
harness_project_dir
AGENT_PROJECT_DIR=
harness_project_dir
unset AGENT_PROJECT_DIR CLAUDE_PROJECT_DIR
harness_project_dir
''')
        self.assertEqual(output, "\n/vendor project/[one]*\n/neutral project/[two]*\n"
                         "/neutral project/[two]*\n/changed vendor project\n\n")

    def test_unknown_is_a_sentinel_only_for_the_remote_hint(self):
        output = self.run_shell('''
AGENT_SESSION_REMOTE=unknown CLAUDE_CODE_REMOTE=true
AGENT_SHELL=unknown CLAUDECODE=1
AGENT_PROJECT_DIR=unknown CLAUDE_PROJECT_DIR='/vendor project'
harness_remote
harness_agent_shell
harness_project_dir
''')
        self.assertEqual(output, "true\nunknown\nunknown\n")

    def test_direct_helper_calls_leave_classifier_and_caller_unchanged(self):
        # Invoke the helpers directly: command substitutions would conceal
        # mutations in subshells and make this non-interference test ineffective.
        output = self.run_shell('''
AGENT_SESSION_REMOTE=false
AGENT_SHELL=1 CLAUDECODE=0
AGENT_PROJECT_DIR='/neutral project' CLAUDE_PROJECT_DIR='/vendor project'
set -- retained arguments
before_options="$-"; before_pwd="$PWD"
before_classifier="$(declare -p AGENT_SESSION_ENVIRONMENT AGENT_SESSION_SIGNAL AGENT_SESSION_REMOTE AGENT_SESSION_EPHEMERAL)"
harness_remote
harness_agent_shell
harness_project_dir
[ "$before_classifier" = "$(declare -p AGENT_SESSION_ENVIRONMENT AGENT_SESSION_SIGNAL AGENT_SESSION_REMOTE AGENT_SESSION_EPHEMERAL)" ]
[ "$before_options" = "$-" ] && [ "$before_pwd" = "$PWD" ] && [ "$*" = 'retained arguments' ]
printf '%s|%s|%s|%s\\n' "$AGENT_SESSION_ENVIRONMENT" "$AGENT_SESSION_SIGNAL" "$AGENT_SESSION_REMOTE" "$AGENT_SESSION_EPHEMERAL"
''', {"CLAUDE_CODE_REMOTE": "true"})
        self.assertEqual(output, "false\n1\n/neutral project\n"
                         "cloud|CLAUDE_CODE_REMOTE|false|true\n")

    def test_source_normalization_precedes_legacy_hint_lookup(self):
        output = self.run_shell('''
printf '%s|%s|%s|%s\\n' "$AGENT_SESSION_ENVIRONMENT" "$AGENT_SESSION_SIGNAL" "$AGENT_SESSION_REMOTE" "$AGENT_SESSION_EPHEMERAL"
harness_remote
''', {"AGENT_SESSION_REMOTE": "false", "CLAUDE_CODE_REMOTE": "true"})
        self.assertEqual(output, "cloud|CLAUDE_CODE_REMOTE|true|true\ntrue\n")

    def test_positive_hint_does_not_classify_an_unknown_session(self):
        output = self.run_shell('''
CLAUDE_CODE_REMOTE=true
before_classifier="$(declare -p AGENT_SESSION_ENVIRONMENT AGENT_SESSION_SIGNAL AGENT_SESSION_REMOTE AGENT_SESSION_EPHEMERAL)"
harness_remote
[ "$before_classifier" = "$(declare -p AGENT_SESSION_ENVIRONMENT AGENT_SESSION_SIGNAL AGENT_SESSION_REMOTE AGENT_SESSION_EPHEMERAL)" ]
printf '%s|%s|%s|%s\\n' "$AGENT_SESSION_ENVIRONMENT" "$AGENT_SESSION_SIGNAL" "$AGENT_SESSION_REMOTE" "$AGENT_SESSION_EPHEMERAL"
''')
        self.assertEqual(output, "true\nunknown|none|unknown|false\n")


unittest.main(verbosity=2)
PY
