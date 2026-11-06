#!/usr/bin/env bash
# Retirement removes shared entry points; adoption preserves local skills and old work.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

for surface in .agents/skills .claude/skills; do
    retired="$ROOT/$surface/task-queue"
    [[ ! -e "$retired" && ! -L "$retired" ]] || fail "retired entry remains: $retired"
done
[[ -r "$ROOT/docs/task-queue-retirement.md" ]] || fail 'recovery guidance missing'
grep -Fq 'docs/task-queue-retirement.md)' "$ROOT/README.md"
grep -Fq '../../../docs/task-queue-retirement.md)' "$ROOT/.agents/skills/task-create/bucket-definitions.md"

# Use the actual current roster and generator in an isolated consumer. Seed the
# old shared skill first so both stale links provably resolve before removal.
repo="$scratch/repo"
mkdir -p "$repo/workshop/.agents" "$repo/workshop/Tools" "$repo/.agents/skills" "$repo/.claude/skills"
cp -R "$ROOT/.agents/skills" "$repo/workshop/.agents/"
cp "$ROOT/Tools/sync-skill-symlinks.sh" "$repo/workshop/Tools/"
mkdir -p "$repo/workshop/.agents/skills/task-queue"
printf 'retired fixture\n' > "$repo/workshop/.agents/skills/task-queue/SKILL.md"
ln -s '../../workshop/.agents/skills/task-queue' "$repo/.agents/skills/task-queue"
ln -s '../../.agents/skills/task-queue' "$repo/.claude/skills/task-queue"
for surface in .agents/skills .claude/skills; do
    [[ -r "$repo/$surface/task-queue/SKILL.md" ]] || fail 'stale-link setup failed'
done
mkdir -p "$repo/.agents/skills/local-only" "$repo/docs/work/tasks/queued" "$repo/.task-queue"
printf 'local skill\n' > "$repo/.agents/skills/local-only/SKILL.md"
ln -s '../../.agents/skills/local-only' "$repo/.claude/skills/local-only"
printf 'unfinished work\n' > "$repo/docs/work/tasks/queued/unfinished.md"
printf 'recovery evidence\n' > "$repo/.task-queue/state"
rm -r "$repo/workshop/.agents/skills/task-queue"
bash "$repo/workshop/Tools/sync-skill-symlinks.sh" "$repo"
for surface in .agents/skills .claude/skills; do
    retired="$repo/$surface/task-queue"
    [[ ! -e "$retired" && ! -L "$retired" ]] || fail "stale shared link survives: $surface"
    [[ "$(cat "$repo/$surface/local-only/SKILL.md")" == 'local skill' ]] || fail 'local skill changed'
    for skill in task-next task-finalize task-implement audit-and-fix audit-next audit-done; do
        [[ -r "$repo/$surface/$skill/SKILL.md" ]] || fail "supported skill missing: $surface/$skill"
    done
done
[[ "$(cat "$repo/docs/work/tasks/queued/unfinished.md")" == 'unfinished work' ]] || fail 'old brief changed'
[[ "$(cat "$repo/.task-queue/state")" == 'recovery evidence' ]] || fail 'old state changed'

# A project-local skill with the retired name belongs to its project too.
mkdir -p "$repo/.agents/skills/task-queue"
printf 'project-owned skill\n' > "$repo/.agents/skills/task-queue/SKILL.md"
ln -s '../../.agents/skills/task-queue' "$repo/.claude/skills/task-queue"
bash "$repo/workshop/Tools/sync-skill-symlinks.sh" "$repo"
for surface in .agents/skills .claude/skills; do
    [[ "$(cat "$repo/$surface/task-queue/SKILL.md")" == 'project-owned skill' ]] || fail 'project-owned retired name changed'
done
echo 'PASS: retired shared entries absent; recovery linked; adoption preserves supported skills and old work'
