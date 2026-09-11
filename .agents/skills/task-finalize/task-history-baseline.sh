#!/usr/bin/env bash
# Classify a task-history baseline, or choose the conservative baseline a
# finalization should record. The repository being inspected is always an
# explicit input; this script's own location never selects it.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage:
  bash task-history-baseline.sh check <task-repo> <inspected-commit> <finalized-at>
  bash task-history-baseline.sh select <task-repo> <inspected-commit>
EOF
}

emit() { printf '%s=%s\n' "$1" "$2"; }

if [ "$#" -lt 1 ]; then usage; exit 2; fi
mode="$1"
shift

case "$mode:$#" in
    check:3 | select:2) ;;
    *) usage; exit 2 ;;
esac

repo="$1"
inspected="$2"
if ! repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "task repository is not a Git worktree: $1" >&2
    exit 2
fi
repo="$(cd -P "$repo" && pwd)"

if ! [[ "$inspected" =~ ^[0-9a-f]{40}$ ]] \
    || ! git -C "$repo" cat-file -e "$inspected^{commit}" 2>/dev/null; then
    emit STATUS error
    emit REASON "inspected commit is unavailable: $inspected"
    exit 2
fi

if [ "$mode" = check ]; then
    stamp="$3"
    if ! [[ "$stamp" =~ ^[0-9a-f]{40}$ ]]; then
        emit STATUS malformed
        emit REASON "finalized-at is not a 40-hex commit SHA: $stamp"
        exit 1
    fi
    if [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
        emit STATUS reverify
        emit REASON "repository history is shallow"
        exit 0
    fi
    if ! git -C "$repo" cat-file -e "$stamp^{commit}" 2>/dev/null; then
        emit STATUS reverify
        emit REASON "finalized-at commit is unavailable: $stamp"
        exit 0
    fi
    ancestry_rc=0
    git -C "$repo" merge-base --is-ancestor "$stamp" "$inspected" >/dev/null 2>&1 \
        || ancestry_rc=$?
    if [ "$ancestry_rc" -eq 1 ]; then
        emit STATUS reverify
        emit REASON "finalized-at commit is outside the inspected commit's ancestry: $stamp"
        exit 0
    elif [ "$ancestry_rc" -ne 0 ]; then
        emit STATUS error
        emit REASON "Git could not compare finalized-at with the inspected commit"
        exit 2
    fi
    emit STATUS usable
    emit BASELINE "$stamp"
    emit REASON "finalized-at is an ancestor of the inspected commit"
    exit 0
fi

fallback() {
    emit BASELINE "$inspected"
    emit DURABILITY limited
    emit REASON "$1"
    exit 0
}

if [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    fallback "repository history is shallow; recording the inspected commit"
fi

mapfile -t default_refs < <(
    git -C "$repo" for-each-ref --format='%(refname) %(symref)' refs/remotes |
        awk '$1 ~ /^refs\/remotes\/[^/]+\/HEAD$/ && $2 != "" { print $1 " " $2 }'
)
if [ "${#default_refs[@]}" -ne 1 ]; then
    fallback "authoritative default remote and branch are absent or ambiguous; recording the inspected commit"
fi

read -r head_ref target_ref <<<"${default_refs[0]}"
remote="${head_ref#refs/remotes/}"
remote="${remote%/HEAD}"
expected_prefix="refs/remotes/$remote/"
if [[ "$target_ref" != "$expected_prefix"* ]]; then
    fallback "remote HEAD does not name a branch for its remote; recording the inspected commit"
fi
branch="${target_ref#"$expected_prefix"}"

fetch_rc=0
git -C "$repo" fetch --no-tags "$remote" "$branch" >/dev/null 2>&1 || fetch_rc=$?
if [ "$fetch_rc" -ne 0 ]; then
    fallback "fetch of $remote/$branch failed; recording the inspected commit"
fi
if ! fetched="$(git -C "$repo" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)"; then
    fallback "freshly fetched default branch has no commit tip; recording the inspected commit"
fi

merge_output=""
if ! merge_output="$(git -C "$repo" merge-base --all "$inspected" "$fetched" 2>/dev/null)"; then
    fallback "Git could not establish a shared baseline; recording the inspected commit"
fi
mapfile -t bases <<<"$merge_output"
if [ "${#bases[@]}" -ne 1 ]; then
    fallback "a unique shared baseline is unavailable; recording the inspected commit"
fi
baseline="${bases[0]}"
for tip in "$inspected" "$fetched"; do
    ancestry_rc=0
    git -C "$repo" merge-base --is-ancestor "$baseline" "$tip" >/dev/null 2>&1 \
        || ancestry_rc=$?
    if [ "$ancestry_rc" -ne 0 ]; then
        fallback "the shared baseline could not be verified against both histories; recording the inspected commit"
    fi
done

emit BASELINE "$baseline"
emit DURABILITY conservative
emit REASON "unique merge-base with freshly fetched $remote/$branch"
