#!/usr/bin/env bash
# Tests for Tools/hooks/.gitignore — the whitelist that keeps foreign git hooks
# out of Workshop's tracked hooks directory.
#
# Workshop points every consumer's core.hooksPath at Tools/hooks/, and that
# setting is exclusive, so any OTHER hook installer (git lfs, pre-commit, husky)
# must write into this tracked directory for its hook to run at all. The
# contract asserted here:
#
#   1. the tracked contents of Tools/hooks/ are exactly the expected manifest,
#      so a forced `git add -f` of a stray hook fails here before it can land
#      and be distributed to every consumer;
#   2. a foreign hook name arriving in that directory is ignored, so it does not
#      show as an untracked file in a consumer's Workshop checkout;
#   3. Workshop's own hooks are NOT ignored, so the whitelist can never hide a
#      real change to one of them.
#
# 2 and 3 read the ignore rules directly with `git check-ignore --no-index`,
# which answers for a path whether or not it currently exists — the property
# being asserted is the rule, not today's directory listing.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WORKSHOP_ROOT"

fail() { echo "FAIL: $1" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "not a git work tree — this test reads the tracked manifest via git ls-files"

# 0 = ignored, 1 = not ignored. check-ignore's other exits mean it could not
# decide, which is an error here rather than a quiet "not ignored".
ignored() {
  local rc=0
  git check-ignore -q --no-index "$1" || rc=$?
  case "$rc" in
    0 | 1) return "$rc" ;;
    *) fail "git check-ignore errored (exit $rc) on $1" ;;
  esac
}

expected="Tools/hooks/.gitignore
Tools/hooks/post-checkout
Tools/hooks/post-merge
Tools/hooks/post-rewrite"

# --- 1. the tracked manifest is exactly the expected set -------------------
actual="$(git ls-files Tools/hooks/)"
if [ "$actual" != "$expected" ]; then
  printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
  fail "the tracked contents of Tools/hooks/ are not the expected manifest.
A foreign hook must never be committed here — it would run in every consumer,
including repos without the tool it belongs to. A new Workshop hook needs both a
whitelist entry in Tools/hooks/.gitignore and an entry in this test."
fi

# --- 2. foreign hook names are ignored -------------------------------------
# pre-push is the one observed in the fleet (git lfs install); the rest stand in
# for the installers that have not collided yet.
for foreign in pre-push pre-commit post-commit prepare-commit-msg pre-rebase; do
  ignored "Tools/hooks/$foreign" ||
    fail "Tools/hooks/$foreign is not ignored — a foreign '$foreign' hook would
show as an untracked file in every consumer that installed it, one 'git add -A'
away from being published to the whole fleet."
done

# --- 3. Workshop's own hooks are not ignored -------------------------------
while IFS= read -r tracked; do
  [ "$tracked" = "Tools/hooks/.gitignore" ] && continue
  if ignored "$tracked"; then
    fail "$tracked is ignored by Tools/hooks/.gitignore — Workshop's own hooks
must stay visible to git status, or a real change to one of them goes unnoticed."
  fi
done <<< "$expected"

echo "PASS: Tools/hooks/ manifest and ignore rules"
