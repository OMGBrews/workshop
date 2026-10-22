#!/usr/bin/env bash
# Exercise the actual detector protocol and source compatibility in fresh shells.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

root = Path(sys.argv.pop()).resolve()
detector = root / 'docs/templates/cloud-sessions/harness-signals.sh'

class DetectorTests(unittest.TestCase):
    def run_detector(self, values=None, args=(), path=detector):
        return subprocess.run(['bash', str(path), *args], text=True,
                              capture_output=True, env={'PATH': os.environ['PATH'], **(values or {})})

    def test_protocol_matrix(self):
        cases = [
            ({}, 0, 'unknown', 'none'),
            ({'AGENT_SESSION_ENVIRONMENT': 'local'}, 0, 'local', 'AGENT_SESSION_ENVIRONMENT'),
            ({'AGENT_SESSION_ENVIRONMENT': 'cloud'}, 0, 'cloud', 'AGENT_SESSION_ENVIRONMENT'),
            ({'CLAUDE_CODE_REMOTE': 'true'}, 0, 'cloud', 'CLAUDE_CODE_REMOTE'),
            ({'CLAUDE_CODE_REMOTE': 'false'}, 0, 'unknown', 'none'),
            ({'AGENT_SESSION_REMOTE': 'true'}, 0, 'cloud', 'AGENT_SESSION_REMOTE'),
            ({'AGENT_SESSION_REMOTE': 'false'}, 0, 'unknown', 'none'),
            ({'AGENT_SESSION_EPHEMERAL': 'true'}, 0, 'cloud', 'AGENT_SESSION_EPHEMERAL'),
            ({'AGENT_SESSION_EPHEMERAL': 'false'}, 0, 'unknown', 'none'),
            ({'AGENT_SESSION_ENVIRONMENT': 'unknown'}, 0, 'unknown', 'none'),
            ({'AGENT_SESSION_ENVIRONMENT': 'cloud', 'CLAUDE_CODE_REMOTE': 'true'},
             0, 'cloud', 'AGENT_SESSION_ENVIRONMENT,CLAUDE_CODE_REMOTE'),
            ({'AGENT_SESSION_ENVIRONMENT': 'local', 'CLAUDE_CODE_REMOTE': 'true'},
             2, 'unknown', 'conflict:AGENT_SESSION_ENVIRONMENT,CLAUDE_CODE_REMOTE'),
        ]
        for values, code, environment, signal in cases:
            with self.subTest(values=values):
                result = self.run_detector(values)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(result.stdout, f'environment={environment} signal={signal}\n')
                self.assertEqual(result.stderr, '')

    def test_invalid_values_are_errors(self):
        for key in ['AGENT_SESSION_ENVIRONMENT', 'AGENT_SESSION_REMOTE',
                    'AGENT_SESSION_EPHEMERAL', 'CLAUDE_CODE_REMOTE']:
            with self.subTest(key=key):
                result = self.run_detector({key: 'yes\nlocal'})
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, f'environment=unknown signal=invalid_{key}\n')

    def test_explicit_arguments_override_lower_signals(self):
        for requested in ['local', 'cloud']:
            result = self.run_detector({'CLAUDE_CODE_REMOTE': 'true', 'AGENT_SESSION_REMOTE': 'bad'},
                                       ['--environment', requested])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, f'environment={requested} signal=argument\n')
        for args in [ ['local'], ['--environment'], ['--environment', ''],
                     ['--environment', 'unknown'], ['--environment', 'local', 'extra'] ]:
            self.assertEqual(self.run_detector(args=args).returncode, 2)

    def source(self, values):
        return subprocess.run(['bash', '-c', '''
set -eu
set -- retained arguments
before_options="$-"; before_pwd="$PWD"
. "$DETECTOR"
[ "$before_options" = "$-" ] && [ "$before_pwd" = "$PWD" ] && [ "$*" = 'retained arguments' ]
printf '%s|%s|%s|%s\\n' "$AGENT_SESSION_ENVIRONMENT" "$AGENT_SESSION_SIGNAL" "$AGENT_SESSION_REMOTE" "$AGENT_SESSION_EPHEMERAL"
'''], capture_output=True, text=True,
            env={'PATH': os.environ['PATH'], 'DETECTOR': str(detector), **values})

    def test_source_silent_preserves_caller_and_capability(self):
        cases = [({}, 'unknown|none|unknown|false\n'),
                 ({'AGENT_SESSION_ENVIRONMENT': 'local'}, 'local|AGENT_SESSION_ENVIRONMENT|false|false\n'),
                 ({'AGENT_SESSION_ENVIRONMENT': 'cloud'}, 'cloud|AGENT_SESSION_ENVIRONMENT|true|false\n'),
                 ({'CLAUDE_CODE_REMOTE': 'true'}, 'cloud|CLAUDE_CODE_REMOTE|true|true\n'),
                 ({'AGENT_SESSION_REMOTE': 'true'}, 'cloud|AGENT_SESSION_REMOTE|true|false\n'),
                 ({'CLAUDE_CODE_REMOTE': 'true', 'AGENT_SESSION_EPHEMERAL': 'false'},
                  'cloud|CLAUDE_CODE_REMOTE|true|false\n')]
        for values, expected in cases:
            with self.subTest(values=values):
                result = self.source(values)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_source_failure_clears_mutation_capability(self):
        result = subprocess.run(['bash', '-c', '. "$DETECTOR"; rc=$?; printf "%s|%s|%s\\n" "$rc" "$AGENT_SESSION_ENVIRONMENT" "$AGENT_SESSION_EPHEMERAL"'],
            text=True, capture_output=True, env={'PATH':os.environ['PATH'], 'DETECTOR':str(detector),
                'AGENT_SESSION_ENVIRONMENT':'local', 'AGENT_SESSION_EPHEMERAL':'true'})
        self.assertEqual(result.stdout, '2|unknown|false\n')

    def test_ship_resolves_physical_mount_not_legacy_consumer(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / 'consumer with spaces'
            skills = repo / '.agents/skills'; skills.mkdir(parents=True)
            (repo / 'different-mount').symlink_to(root, target_is_directory=True)
            (skills / 'ship').symlink_to(repo / 'different-mount/.agents/skills/ship', target_is_directory=True)
            old = repo / 'scripts/lib/harness-signals.sh'; old.parent.mkdir(parents=True)
            old.write_text('echo incompatible-old-provider\n')
            physical = (skills / 'ship/SKILL.md').resolve().parent.parent.parent.parent
            result = self.run_detector({'CLAUDE_CODE_REMOTE':'true'},
                path=physical / 'docs/templates/cloud-sessions/harness-signals.sh')
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, 'environment=cloud signal=CLAUDE_CODE_REMOTE\n')

unittest.main()
PY
