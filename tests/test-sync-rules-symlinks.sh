#!/usr/bin/env bash
# Tests for Tools/sync-rules-symlinks.sh.
#
# The script's contract, asserted here:
#   1. writes the three standing-rule links, .claude/rules/<rule>.md ->
#      ../../<mount>/docs/<rule>.md, each resolving to its rule's heading;
#   2. is idempotent — a second run creates nothing;
#   3. removes a stale link it owns (a dangling ../../<mount>/docs/<name>.md),
#      and leaves a real topic file, a repo-local ../../docs/<name>.md link, and
#      any other symlink alone;
#   4. writes ../../docs/<rule>.md when the tree is the repository root, which
#      is Workshop converting itself;
#   5. refuses a tree nested below the mount instead of writing links;
#   6. fails loudly when a link does not resolve to its rule, and on a root with
#      no AGENTS.md (the wrong-directory guard).
#
# Every fixture copies the script into the tree it would ship in, because
# self-location is the discovery mechanism.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$WORKSHOP_ROOT/Tools/sync-rules-symlinks.sh"
RULES="signal-hygiene definition-of-done verification-terminology"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# make_tree <tree-dir>: the script plus the three rules, headings on line one.
make_tree() {
  mkdir -p "$1/Tools" "$1/docs"
  cp "$SYNC" "$1/Tools/sync-rules-symlinks.sh"
  printf '# Signal hygiene\n\nBody.\n' > "$1/docs/signal-hygiene.md"
  printf '# Definition of done\n\nBody.\n' > "$1/docs/definition-of-done.md"
  printf '# Verification terminology\n\nBody.\n' > "$1/docs/verification-terminology.md"
}

# --- 1. fresh run writes the three links -------------------------------------
PROJ="$TMP/proj"
mkdir -p "$PROJ"
echo '# Instructions' > "$PROJ/AGENTS.md"
make_tree "$PROJ/workshop"
out="$(bash "$PROJ/workshop/Tools/sync-rules-symlinks.sh" "$PROJ" 2>&1)" || fail "sync failed on a fresh project: $out"
grep -q '3 linked, 0 already current, 0 stale removed' <<< "$out" || fail "fresh run not reported as 3 linked: $out"
for rule in $RULES; do
  link="$PROJ/.claude/rules/$rule.md"
  [ -L "$link" ] || fail "$rule is not a symlink"
  [ "$(readlink "$link")" = "../../workshop/docs/$rule.md" ] || fail "$rule points at $(readlink "$link")"
  [ -r "$link" ] || fail "$rule does not resolve"
done
[ "$(head -n 1 "$PROJ/.claude/rules/verification-terminology.md")" = '# Verification terminology' ] \
  || fail "the terminology link does not land on the terminology rule"
echo "ok 1 - writes the three standing-rule links into the mount"

# --- 2. idempotent -----------------------------------------------------------
out="$(bash "$PROJ/workshop/Tools/sync-rules-symlinks.sh" "$PROJ" 2>&1)" || fail "second run failed: $out"
grep -q '0 linked, 3 already current, 0 stale removed' <<< "$out" || fail "second run not idempotent: $out"
echo "ok 2 - idempotent"

# --- 3. stale owned link swept; everything else left alone -------------------
mkdir -p "$PROJ/docs"
echo '# Database hygiene' > "$PROJ/docs/database-hygiene.md"
ln -s ../../docs/database-hygiene.md "$PROJ/.claude/rules/database-hygiene.md"   # repo-local, hand-made
ln -s ../../devtools/docs/retired-rule.md "$PROJ/.claude/rules/retired-rule.md"  # owned shape, dangling
ln -s ../../elsewhere/notes.md "$PROJ/.claude/rules/foreign.md"                   # not owned, dangling
echo '# Cloud sessions' > "$PROJ/.claude/rules/cloud-sessions.md"                 # real topic file
out="$(bash "$PROJ/workshop/Tools/sync-rules-symlinks.sh" "$PROJ" 2>&1)" || fail "sync failed with extra entries present: $out"
grep -q '1 stale removed' <<< "$out" || fail "stale owned link not reported removed: $out"
if [ -e "$PROJ/.claude/rules/retired-rule.md" ] || [ -L "$PROJ/.claude/rules/retired-rule.md" ]; then
  fail "stale owned link still present"
fi
[ "$(readlink "$PROJ/.claude/rules/database-hygiene.md")" = "../../docs/database-hygiene.md" ] \
  || fail "the repo-local link was touched"
[ "$(readlink "$PROJ/.claude/rules/foreign.md")" = "../../elsewhere/notes.md" ] \
  || fail "a foreign symlink was touched"
if [ ! -f "$PROJ/.claude/rules/cloud-sessions.md" ] || [ -L "$PROJ/.claude/rules/cloud-sessions.md" ]; then
  fail "the real topic file was touched"
fi
[ "$(cat "$PROJ/.claude/rules/cloud-sessions.md")" = '# Cloud sessions' ] || fail "the real topic file was rewritten"
echo "ok 3 - stale owned link removed; repo-local link, foreign link, and topic file untouched"

# A real file in a standing rule's place is refused, never overwritten.
rm "$PROJ/.claude/rules/signal-hygiene.md"
echo '# Signal hygiene (a stale copy)' > "$PROJ/.claude/rules/signal-hygiene.md"
if out="$(bash "$PROJ/workshop/Tools/sync-rules-symlinks.sh" "$PROJ" 2>&1)"; then
  fail "sync passed over a real file in a standing rule's place: $out"
fi
grep -q 'is a real file' <<< "$out" || fail "the real file was not named: $out"
[ ! -L "$PROJ/.claude/rules/signal-hygiene.md" ] || fail "the real file was replaced by a link"
echo "ok 3b - a real file in a standing rule's place is refused, not overwritten"

# --- 4. the tree is the repository root (Workshop itself) --------------------
SELF="$TMP/self"
make_tree "$SELF"
echo '# Instructions' > "$SELF/AGENTS.md"
out="$(bash "$SELF/Tools/sync-rules-symlinks.sh" "$SELF" 2>&1)" || fail "sync failed at the tree's own root: $out"
for rule in $RULES; do
  [ "$(readlink "$SELF/.claude/rules/$rule.md")" = "../../docs/$rule.md" ] \
    || fail "self-conversion $rule points at $(readlink "$SELF/.claude/rules/$rule.md")"
  [ -r "$SELF/.claude/rules/$rule.md" ] || fail "self-conversion $rule does not resolve"
done
echo "ok 4 - the tree's own root links ../../docs/"

# --- 5. a tree nested below the mount is refused -----------------------------
NEST="$TMP/nest"
mkdir -p "$NEST"
echo '# Instructions' > "$NEST/AGENTS.md"
make_tree "$NEST/wrapper/nested"
if out="$(bash "$NEST/wrapper/nested/Tools/sync-rules-symlinks.sh" "$NEST" 2>&1)"; then
  fail "sync passed for a tree nested below the mount: $out"
fi
grep -q 'nested below the mount' <<< "$out" || fail "the nested layout was not named: $out"
[ ! -e "$NEST/.claude/rules" ] || fail "links were written for a refused layout"
echo "ok 5 - a nested tree is refused before anything is written"

# --- 6. loud failures --------------------------------------------------------
# A rule missing from the mount leaves its link dangling: exit 1, named.
GAP="$TMP/gap"
mkdir -p "$GAP"
echo '# Instructions' > "$GAP/AGENTS.md"
make_tree "$GAP/workshop"
rm "$GAP/workshop/docs/definition-of-done.md"
if out="$(bash "$GAP/workshop/Tools/sync-rules-symlinks.sh" "$GAP" 2>&1)"; then
  fail "sync passed with a rule missing from the mount: $out"
fi
grep -q 'does not resolve: .*definition-of-done.md' <<< "$out" || fail "the dangling link was not named: $out"
grep -q 'FAILED' <<< "$out" || fail "the failure was not reported loudly: $out"

# A rule whose first line is wrong is the wrong document.
printf '# Definition of done\n' > "$GAP/workshop/docs/definition-of-done.md"
printf 'Not a heading\n' > "$GAP/workshop/docs/signal-hygiene.md"
if out="$(bash "$GAP/workshop/Tools/sync-rules-symlinks.sh" "$GAP" 2>&1)"; then
  fail "sync passed with a rule missing its heading: $out"
fi
grep -q "does not open with '# Signal hygiene'" <<< "$out" || fail "the wrong heading was not named: $out"

# No AGENTS.md: the wrong-directory guard.
BARE="$TMP/bare"
make_tree "$BARE/workshop"
if out="$(bash "$BARE/workshop/Tools/sync-rules-symlinks.sh" "$BARE" 2>&1)"; then
  fail "sync passed on a root with no AGENTS.md: $out"
fi
grep -q 'no AGENTS.md' <<< "$out" || fail "the missing AGENTS.md was not named: $out"
echo "ok 6 - failure paths are loud"
