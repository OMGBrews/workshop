#!/usr/bin/env bash
# Old commands must fail without dispatching workers or changing the repository.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/repo/docs/work/tasks/queued"
for command in claude git setsid script; do
    cat > "$scratch/bin/$command" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$RETIREMENT_CALLS"
exit 97
STUB
    chmod +x "$scratch/bin/$command"
done
printf 'preserve me\n' > "$scratch/repo/docs/work/tasks/queued/unfinished.md"
for mode in default --foreground recover stop; do
    args=()
    [[ "$mode" == default ]] || args+=("$mode")
    rc=0
    (cd "$scratch/repo" && PATH="$scratch/bin:$PATH" RETIREMENT_CALLS="$scratch/calls" \
        bash "$ROOT/.agents/skills/task-queue/run.sh" "${args[@]}") > "$scratch/output" 2>&1 || rc=$?
    [[ "$rc" == 1 ]] || { echo "FAIL: $mode returned $rc"; exit 1; }
    grep -q 'retired' "$scratch/output"
    [[ ! -e "$scratch/calls" ]] || { cat "$scratch/calls"; exit 1; }
    [[ ! -e "$scratch/repo/.task-queue" ]]
    [[ "$(cat "$scratch/repo/docs/work/tasks/queued/unfinished.md")" == 'preserve me' ]]
done
[[ ! -e "$ROOT/.agents/skills/task-queue/initial-prompt.md" ]]
echo 'PASS: retired entry points refuse dispatch and preserve old work'
