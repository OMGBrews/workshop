#!/usr/bin/env bash
# Contract coverage for every task-history consumer and the rendered worker prompt.

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
require_text ".agents/skills/task-move/SKILL.md" "remains queueable" \
    "task-move admits warning-only briefs"
require_text ".agents/skills/task-queue/execution-discipline.md" \
    "task-history-baseline.sh" "worker invokes the shared history helper"
require_text ".agents/skills/task-queue/execution-discipline.md" \
    "continue autonomously" "worker handles unusable history without a human"

render_root="$(mktemp -d)"
trap 'rm -rf "$render_root"' EXIT
mkdir -p "$render_root/.agents/skills"
cp -R "$ROOT/.agents/skills/task-queue" "$render_root/.agents/skills/task-queue"
git init -q "$render_root"
rendered="$(
    cd "$render_root"
    bash -c '
      source .agents/skills/task-queue/run.sh
      SKILL_DIR="$1"
      PROMPT_FILE="$SKILL_DIR/initial-prompt.md"
      render_worker_prompt
    ' .agents/skills/task-queue/render-check \
      "$render_root/.agents/skills/task-queue"
)"
for expected in task-history-baseline.sh STATUS=reverify "continue autonomously"; do
    if [[ "$rendered" != *"$expected"* ]]; then
        echo "FAIL: rendered worker prompt lacks '$expected'"
        failures=$((failures + 1))
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "$failures task-history consumer assertion(s) failed" >&2
    exit 1
fi
echo "all task-history consumer contracts passed"
