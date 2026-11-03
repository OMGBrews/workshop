#!/usr/bin/env bash
# Strict, read-only task graph check. Completion decisions belong to task-audit.
set -euo pipefail
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo 'usage: bash check-task-dependencies.sh <repo-root>' >&2
    exit 2
fi
repo="$(cd "$1" && pwd -P)"
if ! git_root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" ||
    [ "$(cd "$git_root" && pwd -P)" != "$repo" ]; then
    echo "unavailable input: '$repo' is not a repository root" >&2
    exit 2
fi
tasks="$repo/docs/work/tasks"
if [ ! -d "$tasks" ]; then
    echo "unavailable input: missing tasks root '$tasks'" >&2
    exit 2
fi
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
parser="$script_dir/../.agents/skills/task-finalize/check-task-readiness.sh"
if [ ! -f "$parser" ]; then
    echo "unavailable input: missing bundled parser '$parser'" >&2
    exit 2
fi
inventory="$(mktemp)"
trap 'rm -f "$inventory"' EXIT
declare -a briefs=() slugs=()
for bucket in now soon later finalized parked queued; do
    [ -d "$tasks/$bucket" ] || continue
    if ! find "$tasks/$bucket" -type f -name '*.md' -print0 > "$inventory"; then
        echo "unavailable input: could not inspect '$tasks/$bucket'" >&2
        exit 2
    fi
    while IFS= read -r -d '' brief; do
        case "${brief##*/}" in
            README.md | _TEMPLATE.md | focus.md) continue ;;
        esac
        briefs+=("$brief")
        slug="${brief##*/}"
        slugs+=("${slug%.md}")
    done < "$inventory"
done
failures=0
edges=0
for index in "${!briefs[@]}"; do
    brief="${briefs[$index]}"
    relative="${brief#"$repo/"}"
    case "$relative" in
        docs/work/tasks/queued/*) printf 'LEGACY %s: recovery required; detection only\n' "$relative" ;;
    esac
    duplicates=0
    for slug in "${slugs[@]}"; do
        if [ "$slug" = "${slugs[$index]}" ]; then duplicates=$((duplicates + 1)); fi
    done
    if [ "$duplicates" -gt 1 ]; then
        printf 'FAIL %s: ambiguous task slug %s (%s briefs)\n' "$relative" "${slugs[$index]}" "$duplicates"
        failures=$((failures + 1))
    fi
    if ! dependencies="$(bash "$parser" --dependencies "$brief" 2>&1)"; then
        printf 'FAIL %s: invalid dependencies: %s\n' "$relative" "$dependencies"
        failures=$((failures + 1))
        continue
    fi
    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        edges=$((edges + 1))
        matches=0
        for slug in "${slugs[@]}"; do
            if [ "$slug" = "$dependency" ]; then matches=$((matches + 1)); fi
        done
        if [ "$matches" -eq 0 ]; then
            printf 'FAIL %s: missing dependency %s\n' "$relative" "$dependency"
            failures=$((failures + 1))
        elif [ "$matches" -gt 1 ]; then
            printf 'FAIL %s: ambiguous dependency %s (%s briefs)\n' "$relative" "$dependency" "$matches"
            failures=$((failures + 1))
        fi
    done <<<"$dependencies"
done
printf 'Inspected %s briefs and %s dependency edges; %s failures\n' "${#briefs[@]}" "$edges" "$failures"
[ "$failures" -eq 0 ]
