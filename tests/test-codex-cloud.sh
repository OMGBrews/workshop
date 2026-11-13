#!/usr/bin/env bash
# Exercise the public Codex declaration and manual renderer without platform access.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/tests/test_codex_cloud.py"
