#!/usr/bin/env bash
# Tests for the audit-and-fix selector (.agents/skills/audit-and-fix/select_next.py).
#
# The suite's contract, asserted by the modules it discovers:
#   1. every test_selector_*.py module runs and passes under the stdlib
#      unittest discovery rooted AT the test directory (plain `import support`);
#   2. the end-to-end module drives the REAL subprocess path through a shimmed
#      `python3` on PATH — no subprocess.run mock — proving the selector emits
#      nothing until the tracker child exits and that only the tracker's own
#      exit-0 shapes can produce a success-shaped result;
#   3. the run never writes bytecode into the pinned skill mount
#      (PYTHONDONTWRITEBYTECODE=1, and the selector/tracker never import as
#      cached modules in the tests' process either).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PYTHONDONTWRITEBYTECODE=1

exec python3 -m unittest discover -s tests/audit-tracker -t tests/audit-tracker -p 'test_selector_*.py'
