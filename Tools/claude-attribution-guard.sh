#!/usr/bin/env bash
# Thin Claude PreToolUse adapter. Only a positive detector verdict denies.
set -uo pipefail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
python3 "$(dirname "$SELF")/check-ai-attribution.py" claude-hook || exit 0
