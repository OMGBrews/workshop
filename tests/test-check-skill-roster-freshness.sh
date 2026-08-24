#!/usr/bin/env bash
# Tests for Tools/check-skill-roster-freshness.sh and its git hooks.
#
# The contract asserted here:
#   1. baseline records the entry set; check is silent while it is unchanged.
#   2. an entry-set change makes check print the warning, the reload
#      instruction, and name-level +/- lines, and still exit 0.
#   3. the warning fires once per change (rebaseline), so a second check is
#      silent; a further change warns again.
#   4. a rename produces both a - and a + line naming the two names.
#   5. without a session-start baseline the LAST-state fallback still warns on
#      a change (and the first-ever check records silently).
#   6. end-to-end through git: with core.hooksPath wired, a merge that changes
#      the entry set emits the warning into the merge's own output.
set -euo pipefail

DEVTOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$DEVTOOLS_ROOT/Tools/check-skill-roster-freshness.sh"
HOOKS="$DEVTOOLS_ROOT/Tools/hooks"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Fixture: a consumer repo whose skill entries are symlinks into a nested
# devtools mount — the fleet shape, where the roster-relevant state is the
# entry NAMES, not the content behind them.
PROJ="$TMP/consumer"
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email test@test
git -C "$PROJ" config user.name test
for s in alpha beta; do
  mkdir -p "$PROJ/devtools/.agents/skills/$s"
  echo "# $s" > "$PROJ/devtools/.agents/skills/$s/SKILL.md"
  mkdir -p "$PROJ/.claude/skills"
  ln -s "../../devtools/.agents/skills/$s" "$PROJ/.claude/skills/$s"
done
git -C "$PROJ" add -A
git -C "$PROJ" commit -qm base
git -C "$PROJ" branch baseline-branch

in_proj() { git -C "$PROJ" "$@"; }
check_in() { (cd "$PROJ" && bash "$CHECK" "$@"); }

# --- 1. baseline + silence on no change -------------------------------------
check_in baseline
out="$(check_in check)" || fail "check exited non-zero on an unchanged tree"
[ -z "$out" ] || fail "check not silent on an unchanged tree: $out"
[ -f "$PROJ/.git/skills-roster-baseline" ] || fail "baseline file not written"
echo "ok 1 - baseline records, unchanged tree is silent"

# --- 2. addition warns, once ------------------------------------------------
ln -s "../../devtools/.agents/skills/gamma" "$PROJ/.claude/skills/gamma"
out="$(check_in check)" || fail "check exited non-zero on a change"
echo "$out" | grep -q 'SKILL ROSTER CHANGED' || fail "no warning line: $out"
echo "$out" | grep -q '^+ .claude/skills: gamma' || fail "addition not named: $out"
echo "$out" | grep -q '/reload' || fail "no reload instruction: $out"
out2="$(check_in check)" || fail "check exited non-zero after rebaseline"
[ -z "$out2" ] || fail "warning repeated without a new change: $out2"
echo "ok 2 - addition warns once with the name and the instruction"

# --- 3. rename produces both directions -------------------------------------
rm "$PROJ/.claude/skills/beta"
ln -s "../../devtools/.agents/skills/beta2" "$PROJ/.claude/skills/beta2"
out="$(check_in check)" || fail "check exited non-zero on a rename"
echo "$out" | grep -q '^+ .claude/skills: beta2' || fail "new name not named: $out"
echo "$out" | grep -q '^- .claude/skills: beta' || fail "old name not named: $out"
echo "ok 3 - rename names both the old and the new command"

# --- 4. LAST-state fallback without a baseline ------------------------------
rm "$PROJ/.git/skills-roster-baseline"
rm "$PROJ/.git/skills-roster-last"
out="$(check_in check)" || fail "first fallback check exited non-zero"
[ -z "$out" ] || fail "first-ever check should record silently: $out"
ln -s "../../devtools/.agents/skills/delta" "$PROJ/.claude/skills/delta"
out="$(check_in check)" || fail "fallback check exited non-zero on a change"
echo "$out" | grep -q 'since the last git operation' || fail "fallback wording missing: $out"
echo "$out" | grep -q '^+ .claude/skills: delta' || fail "fallback change not named: $out"
echo "ok 4 - fallback compares against the previous git operation"

# --- 5. end-to-end through git: post-merge hook -----------------------------
# Clean main back to {alpha,beta} (tests 2-4 left uncommitted links), baseline
# it, then land a skill addition through a real merge and expect the hook's
# warning inside the merge's own output.
rm -f "$PROJ/.claude/skills/gamma" "$PROJ/.claude/skills/beta2" "$PROJ/.claude/skills/delta"
ln -s "../../devtools/.agents/skills/beta" "$PROJ/.claude/skills/beta"
git -C "$PROJ" checkout -q main
rm "$PROJ/.git/skills-roster-last" "$PROJ/.git/skills-roster-baseline" 2>/dev/null || true
check_in baseline
in_proj config core.hooksPath "$HOOKS"
git -C "$PROJ" checkout -q -b roster-branch
mkdir -p "$PROJ/devtools/.agents/skills/epsilon"
echo "# epsilon" > "$PROJ/devtools/.agents/skills/epsilon/SKILL.md"
ln -s "../../devtools/.agents/skills/epsilon" "$PROJ/.claude/skills/epsilon"
git -C "$PROJ" add -A
git -C "$PROJ" commit -qm "add epsilon"
git -C "$PROJ" checkout -q main
out="$(in_proj merge -q roster-branch 2>&1)" || fail "merge failed"
echo "$out" | grep -q 'SKILL ROSTER CHANGED' || fail "post-merge hook did not fire: $out"
echo "$out" | grep -q '^+ .claude/skills: epsilon' || fail "merge-added skill not named: $out"
echo "ok 5 - post-merge hook warns inside the merge's own output"

# --- 6. a plain file on a skills surface is not a roster entry --------------
# `sync-skill-symlinks.sh` drops a generated README.md into .claude/skills/.
# No skill name changes when it lands, so a session's roster is not stale and
# the operator must not be sent to /reload-skills over it — a warning that
# cries wolf on a signpost is a warning nobody reads on the real rename.
check_in baseline
echo '# bridge' > "$PROJ/.claude/skills/README.md"
out="$(check_in check)" || fail "check exited non-zero after a README landed"
[ -z "$out" ] || fail "a generated README was reported as a roster change: $out"
# The same surface must still speak up for an actual skill.
ln -s "../../devtools/.agents/skills/zeta" "$PROJ/.claude/skills/zeta"
out="$(check_in check)" || fail "check exited non-zero on a real change beside a README"
echo "$out" | grep -q '^+ .claude/skills: zeta' || fail "real addition not named: $out"
if echo "$out" | grep -q 'README'; then
  fail "the README appeared in the roster diff: $out"
fi
echo "ok 6 - a generated README is not a roster entry, and does not mask real ones"

echo "all roster-freshness tests passed"
