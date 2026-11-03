#!/usr/bin/env bash
# Exercise the public graph command against temporary consumer repositories.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$root/Tools/check-task-dependencies.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/consumer with spaces"
git init -q "$repo"
tasks="$repo/docs/work/tasks"
verdict() {
    local expected="$1" needle="$2" actual=0
    shift 2
    output="$(bash "$checker" "$@" 2>&1)" || actual=$?
    if [ "$actual" -ne "$expected" ] || ! [[ "$output" == *"$needle"* ]]; then
        printf 'expected exit %s containing %s; got exit %s:\n%s\n' "$expected" "$needle" "$actual" "$output" >&2
        exit 1
    fi
}
brief() {
    mkdir -p "$(dirname "$tasks/$1")"
    printf '%s\n' '---' 'status: blocked' 'effort: small' 'priority: high' "$2" '---' '# Fixture' > "$tasks/$1"
}
verdict 2 usage
verdict 2 usage "$repo" extra
verdict 2 'unavailable input' "$fixture"
verdict 2 'missing tasks root' "$repo"
mkdir -p "$tasks"
verdict 0 'Inspected 0 briefs' "$repo"
brief now/source.md 'dependencies: [target, "parked-target"] # supported comment'
brief soon/target.md 'dependencies: []'
brief parked/parked-target.md 'dependencies: []'
verdict 0 'Inspected 3 briefs and 2 dependency edges; 0 failures' "$repo"
# A failed inventory must not masquerade as an empty passing tree.
mkdir "$fixture/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fixture/bin/find"
chmod +x "$fixture/bin/find"
PATH="$fixture/bin:$PATH" verdict 2 'could not inspect' "$repo"
brief now/source.md $'dependencies:\n  - target # comment\n  - \'parked-target\''
verdict 0 '0 failures' "$repo"
# Administrative files must not be parsed or accepted as targets.
for name in README.md _TEMPLATE.md focus.md; do
    printf 'not a brief\n' > "$tasks/soon/$name"
done
verdict 0 'Inspected 3 briefs' "$repo"
brief now/source.md 'dependencies: [focus]'
verdict 1 'missing dependency focus' "$repo"
brief now/source.md 'dependencies: [missing]'
verdict 1 'now/source.md: missing dependency missing' "$repo"
for invalid in $'dependencies:\n  not-a-list' 'dependencies: scalar' 'dependencies: [target,]' 'dependencies: [Bad_Slug]' $'dependencies: []\ndependencies: []'; do
    brief now/source.md "$invalid"
    verdict 1 'now/source.md: invalid dependencies' "$repo"
done
brief now/source.md 'priority: low'
verdict 1 'missing frontmatter field: dependencies' "$repo"
printf '%s\n' '---' 'dependencies: []' > "$tasks/now/source.md"
verdict 1 'unclosed frontmatter' "$repo"
brief now/source.md 'dependencies: [target]'
brief later/target.md 'dependencies: []'
verdict 1 'ambiguous dependency target (2 briefs)' "$repo"
rm "$tasks/later/target.md"
brief queued/blocked/legacy.md 'dependencies: [missing]'
verdict 1 'queued/blocked/legacy.md: missing dependency missing' "$repo"
[[ "$output" == *'LEGACY docs/work/tasks/queued/blocked/legacy.md'* ]]
brief queued/blocked/legacy.md 'dependencies: []'
brief finalized/ready.md 'dependencies: [legacy]'
verdict 0 '0 failures' "$repo"
# Simulate confirmed completion: exact removal retains unrelated metadata/edge.
brief now/source.md 'dependencies: [target, parked-target]'
cp "$tasks/now/source.md" "$fixture/before"
rm "$tasks/soon/target.md"
verdict 1 'now/source.md: missing dependency target' "$repo"
python3 - "$tasks/now/source.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('[target, parked-target]', '[parked-target]'))
PY
verdict 0 '0 failures' "$repo"
python3 - "$fixture/before" "$tasks/now/source.md" <<'PY'
import pathlib, sys
before, after = [pathlib.Path(p).read_text() for p in sys.argv[1:]]
assert after == before.replace('[target, parked-target]', '[parked-target]')
assert 'status: blocked' in after
PY
# Removing the only prerequisite produces the canonical empty-list spelling.
brief now/source.md 'dependencies: [parked-target]'
python3 - "$tasks/now/source.md" <<'PYCODE'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('[parked-target]', '[]'))
PYCODE
verdict 0 '0 failures' "$repo"
# The command leaves the checked brief unchanged.
before="$(git -C "$repo" diff --no-index /dev/null "$tasks/now/source.md" || [ "$?" -eq 1 ])"
verdict 0 '0 failures' "$repo"
after="$(git -C "$repo" diff --no-index /dev/null "$tasks/now/source.md" || [ "$?" -eq 1 ])"
[ "$before" = "$after" ]
echo 'task dependency graph fixtures passed'
