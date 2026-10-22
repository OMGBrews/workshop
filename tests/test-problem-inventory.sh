#!/usr/bin/env bash
# Exercise discovery on mixed and malformed collections, including untracked files.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root/.agents/skills/problem-create/list-records.py" <<'PY'
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
helper = Path(sys.argv.pop())
spec = importlib.util.spec_from_file_location('problem_inventory', helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.root = self.repo / 'docs/work/problems'

    def put(self, path):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('# A prose record\n')
        return p

    def test_absent_empty_distinct(self):
        self.assertEqual(module.inventory(self.repo)['state'], 'absent')
        self.put('README.md')
        self.put('now/.gitkeep')
        self.assertEqual(module.inventory(self.repo), {'state': 'empty', 'records': []})

    def test_mixed_untracked_and_parked(self):
        for p in ['legacy.md', 'now/urgent.md', 'soon/next.md',
                  'later/deferred.md', 'never/parked.md', 'README.md',
                  'now/README.md', '_TEMPLATE.md', 'soon/_TEMPLATE.md']:
            self.put(p)
        result = module.inventory(self.repo)
        self.assertEqual(len(result['records']), 5)
        self.assertEqual({r['bucket'] for r in result['records']},
                         {'unbucketed', 'now', 'soon', 'later', 'never'})
        self.assertTrue(all((self.repo / r['path']).is_file() for r in result['records']))
        process = subprocess.run([sys.executable, str(helper), str(self.repo)],
                                 capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout), result)

    def test_move_preserves_identity_and_second_inventory(self):
        p = self.put('legacy.md')
        before = module.inventory(self.repo)
        (self.root / 'now').mkdir()
        p.rename(self.root / 'now/legacy.md')
        after = module.inventory(self.repo)
        self.assertEqual([r['slug'] for r in before['records']],
                         [r['slug'] for r in after['records']])
        self.assertEqual(after['records'][0]['bucket'], 'now')
        self.assertEqual(module.inventory(self.repo), after)

    def test_duplicate_fails_cli_without_partial_inventory(self):
        self.put('legacy.md'); self.put('never/legacy.md')
        process = subprocess.run([sys.executable, str(helper), str(self.repo)],
                                 capture_output=True, text=True)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(process.stdout, '')
        self.assertIn('duplicate slug', process.stderr)

    def test_unknown_or_deeper_records_refused(self):
        for name in ['queued/flaw.md', 'now/nested/flaw.md']:
            with self.subTest(name=name):
                p = self.put(name)
                with self.assertRaisesRegex(ValueError, 'unsupported record location'):
                    module.inventory(self.repo)
                p.unlink()

    def test_symlink_refused(self):
        self.root.mkdir(parents=True)
        (self.root / 'now').symlink_to(self.repo, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            module.inventory(self.repo)

unittest.main()
PY
