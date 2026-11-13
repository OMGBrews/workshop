"""Public declaration behavior, rendering and failure contracts."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import sys
sys.dont_write_bytecode = True

TOOL = Path(__file__).resolve().parents[1] / 'Tools/codex-cloud.py'
spec = importlib.util.spec_from_file_location('codex_cloud', TOOL)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DeclarationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'remote', 'add', 'origin',
                        'https://github.com/example/project.git'], check=True)
        (self.root / 'docs/work').mkdir(parents=True)
        (self.root / 'scripts').mkdir()
        for name in ('install.sh', 'start.sh'):
            (self.root / 'scripts' / name).write_text('exit 99\n')
        self.config = dict(version=1, availability='configured',
            primaryRepository='example/project', additionalRepositories=[],
            environment=dict(name='example', configId='opaque config', versionId='opaque version',
                checkoutPath='/workspace/a project', installScript='scripts/install.sh',
                startCommand=['bash', 'scripts/start.sh', 'start', '{source}'],
                commandPrefix=['bash', 'scripts/start.sh', 'run'],
                network=dict(access='restricted', includePackageManagers=True, allowedDomains=[]),
                bindings=[]), readiness=dict(state='unverified'))
        self.document = self.root / module.DOCUMENT
        self.write()

    def write(self):
        self.document.write_text(module.BEGIN + '\n```json\n' + json.dumps(self.config)
                                 + '\n```\n' + module.END)

    def cli(self, command, *args):
        return subprocess.run(['python3', str(TOOL), command, str(self.root), *args],
                              capture_output=True, text=True)

    def test_configured_without_claude_settings(self):
        self.assertEqual(module.validate(self.root), self.config)
        result = self.cli('validate')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('live readiness not verified', result.stdout)
        self.assertEqual(json.loads(self.cli('show', '--json').stdout), self.config)

    def test_render_quotes_paths_and_does_not_execute(self):
        result = self.cli('render-setup')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cd '/workspace/a project'", result.stdout)
        self.assertIn('bash scripts/install.sh', result.stdout)
        source = 'a' * 40
        result = self.cli('render-start', '--source', source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('bash scripts/start.sh start ' + source, result.stdout)
        self.assertNotIn('{source}', result.stdout)
        self.assertIn('bash scripts/start.sh run', result.stdout)
        self.assertEqual(self.cli('render-start', '--source', 'HEAD').returncode, 2)

    def test_negative_states_are_answers_not_renderable(self):
        for state in ('not-configured', 'unsupported'):
            self.config = dict(version=1, availability=state, primaryRepository='example/project',
                               additionalRepositories=[], reason='No prepared setup')
            self.write()
            self.assertEqual(self.cli('validate').returncode, 0)
            self.assertEqual(self.cli('render-setup').returncode, 1)

    def test_missing_and_malformed_blocks(self):
        for content in ('', module.END + module.BEGIN,
                        module.BEGIN + '\n```json\n' + '[' * 10000 + '0' + ']' * 10000 + '\n```\n' + module.END,
                        module.BEGIN + '\n```json\n{"version":1,"version":2}\n```\n' + module.END,
                        module.BEGIN + '\n```json\n[]\n```\n' + module.END):
            with self.subTest(content=content):
                self.document.write_text(content)
                result = self.cli('validate')
                self.assertEqual(result.returncode, 1)
                self.assertNotIn('Traceback', result.stderr)
        self.document.unlink()
        self.assertEqual(self.cli('validate').returncode, 1)

    def test_invalid_fields_fail_cleanly(self):
        mutations = [
            lambda c: c.update(version=True),
            lambda c: c.update(primaryRepository='wrong/repo'),
            lambda c: c.update(availability=[]),
            lambda c: c.update(additionalRepositories=['example/project']),
            lambda c: c.update(reason='contradiction'),
            lambda c: c.update(environment=None),
            lambda c: c['environment'].update(installScript='../outside'),
            lambda c: c['environment'].update(checkoutPath='/workspace/../escape'),
            lambda c: c['environment'].update(startCommand=['bash', 'scripts/start.sh']),
            lambda c: c['environment'].update(commandPrefix=['bash', 'scripts/start.sh', '{source}']),
            lambda c: c['environment']['network'].update(includePackageManagers=1),
            lambda c: c['environment']['network'].update(allowedDomains=['https://example.com']),
            lambda c: c['environment'].update(bindings=[dict(name='TOKEN', kind='variable', required=True, value='secret')]),
            lambda c: c['environment'].update(bindings=[dict(name='TOKEN', kind='network-secret', required=True)]),
            lambda c: c.update(readiness=dict(state='recorded')),
            lambda c: c.update(readiness=dict(state='unverified', evidence='scripts/start.sh')),
        ]
        original = copy.deepcopy(self.config)
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                self.config = copy.deepcopy(original)
                mutate(self.config)
                self.write()
                result = self.cli('validate')
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertNotIn('Traceback', result.stderr)

    def test_external_symlink_is_not_a_repository_script(self):
        (self.root / 'scripts/install.sh').unlink()
        (self.root / 'scripts/install.sh').symlink_to(TOOL)
        self.assertEqual(self.cli('validate').returncode, 1)

    def test_script_path_cannot_be_a_bash_option(self):
        (self.root / '-c').write_text('exit 0\n')
        self.config['environment']['startCommand'] = ['bash', '-c', 'echo injected', '{source}']
        self.write()
        self.assertEqual(self.cli('render-start', '--source', 'a' * 40).returncode, 1)
        self.config['environment']['startCommand'] = ['bash', 'scripts/start.sh', '{source}']
        self.config['environment']['installScript'] = '-c'
        self.write()
        self.assertEqual(self.cli('render-setup').returncode, 1)

    def test_symlink_loop_reports_error(self):
        (self.root / 'scripts/install.sh').unlink()
        (self.root / 'scripts/install.sh').symlink_to('install.sh')
        result = self.cli('validate')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('Traceback', result.stderr)

    def test_recorded_evidence_and_bindings(self):
        self.config['readiness'] = dict(state='recorded', evidence='scripts/start.sh')
        self.config['environment']['bindings'] = [dict(name='TOKEN', kind='network-secret',
                                                      required=True, allowedDomains=['api.example.com'])]
        self.write()
        self.assertEqual(self.cli('validate').returncode, 0)
        self.assertIn('not independently verified', self.cli('show').stdout)


if __name__ == '__main__':
    unittest.main()
