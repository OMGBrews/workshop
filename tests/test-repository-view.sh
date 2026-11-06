#!/usr/bin/env bash
# Exercise the repository-view contract with independent Python and shell users.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$root/tests/repository-view/test_repository_view.py"
