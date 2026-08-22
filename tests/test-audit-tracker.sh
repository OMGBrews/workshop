#!/usr/bin/env bash
# Tests for the audit tracker package (.agents/skills/audit-and-fix/audit_tracker).
#
# The suite's contract, asserted by the modules it discovers:
#   1. every test_tracker_*.py module runs and passes under the stdlib
#      unittest discovery rooted AT the test directory (no package import —
#      the directory name "audit-tracker" is not importable, and -s = -t
#      puts the directory itself on sys.path so plain `import support` works);
#   2. the run never writes bytecode into the pinned skill mount
#      (PYTHONDONTWRITEBYTECODE=1 here, plus the same switch inside the
#      tracker's own launcher);
#   3. the repo-root cache hazard is contained: every test that moves the
#      working tree resets git_utils' per-process repo_root() cache.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PYTHONDONTWRITEBYTECODE=1

exec python3 -m unittest discover -s tests/audit-tracker -t tests/audit-tracker -p 'test_tracker_*.py'
