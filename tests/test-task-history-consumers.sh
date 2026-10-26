#!/usr/bin/env bash
# Contract coverage for every task-history consumer.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

require_text() { # <file> <pattern> <label>
    if ! grep -Fq -- "$2" "$ROOT/$1"; then
        echo "FAIL: $3: $1 lacks '$2'"
        failures=$((failures + 1))
    fi
}

for skill in task-finalize task-implement task-audit; do
    require_text ".agents/skills/$skill/SKILL.md" "task-history-baseline.sh" \
        "$skill invokes the shared history helper"
    require_text ".agents/skills/$skill/SKILL.md" "STATUS=reverify" \
        "$skill carries an explicit full-verification branch"
done
require_text ".agents/skills/task-queue/execution-discipline.md" \
    "task-history-baseline.sh" "interactive discipline invokes the shared history helper"

if [ "$failures" -ne 0 ]; then
    echo "$failures task-history consumer assertion(s) failed" >&2
    exit 1
fi
echo "all task-history consumer contracts passed"
