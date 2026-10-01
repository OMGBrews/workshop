#!/usr/bin/env bash
# Tests for Tools/cloud-git-lfs.sh, against throwaway repositories and a local
# file:// remote. No network; git's real credential-helper chain and git-lfs's
# real transfer and pre-push paths.
#
# The contract asserted here:
#   1. credential-fallback: a working earlier helper still wins; an empty one
#      falls through to the placeholder pair; a rerun adds no second copy.
#   2. pre-push-hook, plain repository: pre-push alone lands in .git/hooks.
#   3. pre-push-hook, run from the repository's own Workshop mount: it wires
#      core.hooksPath to the mount's Tools/hooks as the bootstrap would, adds
#      pre-push there, and leaves Workshop's post-checkout untouched.
#   4. pre-push-hook never overwrites a foreign pre-push, and says so.
#   5. hydrate: --verify fails on pointers; a pull hydrates with a positive
#      count; --include scopes it; patterns matching nothing fail rather than
#      pass on silence; an unreachable endpoint fails.
#   5b. hydrate after a pull whose index update failed: --verify reports the
#      stale entries without changing them, hydrate repairs them and keeps a
#      real edit, and a still-locked index fails.
#   6. session end to end: a pointer-only clone is hydrated, and a push of a
#      new LFS file uploads its object to the remote.
#   7. usage errors exit 2.
#
# git-lfs is required. Its absence fails this test rather than skipping it.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$WORKSHOP_ROOT/Tools/cloud-git-lfs.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

command -v git-lfs >/dev/null 2>&1 || fail "git-lfs is not installed; this test needs it"

# Keep the developer's own helpers, filters and hooks out of every repository here.
mkdir -p "$TMP/home"
export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig"
git config --global user.name test
git config --global user.email test@example.invalid
git config --global init.defaultBranch main

HELPER_KEY='credential.https://github.com.helper'
# shellcheck disable=SC2016  # a git config value, compared literally
FALLBACK='!f() { if [ "$1" = get ]; then printf "%s\n" username=git password=placeholder; fi; }; f'

fill() { printf 'protocol=https\nhost=github.com\n\n' | git -C "$1" credential fill; }

# --- 1. credential-fallback ----------------------------------------------------
git init -q "$TMP/platform"
git -C "$TMP/platform" config --add "$HELPER_KEY" '!f() { echo username=platform; echo password=secret; }; f'
bash "$TOOL" credential-fallback "$TMP/platform" >/dev/null
fill "$TMP/platform" | grep -qx 'username=platform' || fail "a working platform helper did not win"

git init -q "$TMP/empty"
git -C "$TMP/empty" config --add "$HELPER_KEY" '!f() { :; }; f'
bash "$TOOL" credential-fallback "$TMP/empty" >/dev/null
bash "$TOOL" credential-fallback "$TMP/empty" | grep -q 'already installed' || fail "rerun did not report the existing fallback"
out="$(fill "$TMP/empty")"
grep -qx 'username=git' <<<"$out" || fail "an empty platform helper did not fall through to the fallback username"
grep -qx 'password=placeholder' <<<"$out" || fail "the fallback did not supply the placeholder password"
copies="$(git -C "$TMP/empty" config --get-all "$HELPER_KEY" | grep -Fxc "$FALLBACK" || true)"
[ "$copies" = 1 ] || fail "rerun duplicated the fallback ($copies copies)"
echo "ok 1 - credential fallback: platform wins, empty falls through, idempotent"

# --- 2. pre-push-hook, plain repository -----------------------------------------
git init -q "$TMP/plain"
bash "$TOOL" pre-push-hook "$TMP/plain" >/dev/null || fail "pre-push-hook failed on a plain repository"
grep -q 'git lfs pre-push' "$TMP/plain/.git/hooks/pre-push" || fail "no LFS pre-push in .git/hooks"
[ -x "$TMP/plain/.git/hooks/pre-push" ] || fail "installed pre-push is not executable"
[ ! -e "$TMP/plain/.git/hooks/post-checkout" ] || fail "pre-push-hook installed more than pre-push"
bash "$TOOL" pre-push-hook "$TMP/plain" | grep -q 'present' || fail "rerun did not report the existing hook"
echo "ok 2 - pre-push alone lands in .git/hooks"

# --- 3. pre-push-hook from the repository's own Workshop mount ------------------
CONS="$TMP/consumer"
git init -q "$CONS"
mkdir -p "$CONS/workshop/Tools/hooks"
cp "$TOOL" "$WORKSHOP_ROOT/Tools/check-skill-roster-freshness.sh" "$CONS/workshop/Tools/"
cp "$WORKSHOP_ROOT/Tools/hooks/post-checkout" "$CONS/workshop/Tools/hooks/"
before="$(cksum < "$CONS/workshop/Tools/hooks/post-checkout")"
bash "$CONS/workshop/Tools/cloud-git-lfs.sh" pre-push-hook "$CONS" >/dev/null || fail "pre-push-hook failed in a consumer"
[ "$(git -C "$CONS" config core.hooksPath)" = "workshop/Tools/hooks" ] || fail "core.hooksPath not wired to the mount"
grep -q 'git lfs pre-push' "$CONS/workshop/Tools/hooks/pre-push" || fail "no LFS pre-push in the mount's hooks"
[ "$before" = "$(cksum < "$CONS/workshop/Tools/hooks/post-checkout")" ] || fail "Workshop's post-checkout was modified"
[ ! -e "$CONS/.git/hooks/pre-push" ] || fail "pre-push went to .git/hooks, which git ignores under core.hooksPath"
echo "ok 3 - consumer mount: core.hooksPath wired, pre-push added, Workshop hooks untouched"

# --- 4. a foreign pre-push is never overwritten ---------------------------------
git init -q "$TMP/foreign"
printf '#!/bin/sh\necho mine\n' > "$TMP/foreign/.git/hooks/pre-push"
if bash "$TOOL" pre-push-hook "$TMP/foreign" 2>"$TMP/err" >/dev/null; then fail "foreign pre-push reported success"; fi
grep -q 'not overwriting' "$TMP/err" || fail "foreign pre-push refusal not explained"
grep -q 'echo mine' "$TMP/foreign/.git/hooks/pre-push" || fail "foreign pre-push was overwritten"
echo "ok 4 - a foreign pre-push is kept and reported"

# --- fixture: an origin with LFS objects, and a pointer-only clone --------------
ORIGIN="$TMP/origin.git"
WORK="$TMP/work"
git init -q --bare "$ORIGIN"
git init -q "$WORK"
git -C "$WORK" lfs install --local >/dev/null
echo '*.bin filter=lfs diff=lfs merge=lfs -text' > "$WORK/.gitattributes"
mkdir -p "$WORK/assets" "$WORK/reference"
echo "asset payload" > "$WORK/assets/a.bin"
echo "reference payload" > "$WORK/reference/r.bin"
git -C "$WORK" add -A && git -C "$WORK" commit -qm fixture
git -C "$WORK" push -q "file://$ORIGIN" HEAD:main >/dev/null 2>&1
pointer_clone() { # <dir> — no LFS filters registered: the platform clone's shape
  git clone -q -b main "file://$ORIGIN" "$1"
  head -c 40 "$1/assets/a.bin" | grep -q 'git-lfs.github.com/spec' || fail "fixture clone is not pointer-only"
}

# --- 5. hydrate ---------------------------------------------------------------
pointer_clone "$TMP/c5"
if bash "$TOOL" hydrate --verify "$TMP/c5" >/dev/null 2>&1; then fail "--verify passed on pointers"; fi
bash "$TOOL" hydrate --include='assets/**' "$TMP/c5" > "$TMP/out" || fail "scoped hydrate failed"
grep -q "1 files under assets/\*\* hydrated, 0 pointers" "$TMP/out" || fail "scoped hydrate reported no positive count"
[ "$(cat "$TMP/c5/assets/a.bin")" = "asset payload" ] || fail "assets/a.bin not hydrated"
head -c 40 "$TMP/c5/reference/r.bin" | grep -q 'git-lfs.github.com/spec' || fail "--include pulled outside its scope"
if bash "$TOOL" hydrate --include='nothing/**' "$TMP/c5" 2>"$TMP/err" >/dev/null; then fail "an empty census passed"; fi
grep -q 'no LFS-tracked files' "$TMP/err" || fail "empty census not explained"
bash "$TOOL" hydrate "$TMP/c5" | grep -q '2 files under every LFS-tracked file hydrated, 0 pointers' \
  || fail "full hydrate did not report 2 files"

pointer_clone "$TMP/c5b"
git -C "$TMP/c5b" config lfs.url "file://$TMP/no-such-remote.git/info/lfs"
if bash "$TOOL" hydrate "$TMP/c5b" >/dev/null 2>&1; then fail "hydrate passed with an unreachable endpoint"; fi
echo "ok 5 - hydrate: verify, scope, empty census and unreachable endpoint"

# --- 5b. a pull whose index update failed ------------------------------------
# A held index.lock makes `git lfs pull` print "Error updating the Git index"
# and still exit 0: the files are hydrated, the index keeps the pointers' sizes,
# and git status reports every one modified while git diff reports nothing.
stale_clone() { # <dir>
  pointer_clone "$1"
  git -C "$1" lfs install --local --skip-repo >/dev/null
  touch "$1/.git/index.lock"
  git -C "$1" lfs pull >/dev/null 2>&1 || true
  rm -f "$1/.git/index.lock"
  [ "$(git -C "$1" status --porcelain | wc -l)" = 2 ] || fail "fixture did not reproduce the stale index"
}
stale_clone "$TMP/c5c"
echo "edited" > "$TMP/c5c/reference/r.bin"  # a real edit: content differs, so it is not stale
if bash "$TOOL" hydrate --verify "$TMP/c5c" >/dev/null 2>"$TMP/err"; then fail "--verify passed a stale index"; fi
grep -q 'index entries are stale' "$TMP/err" || fail "--verify did not name the stale index"
grep -q 'assets/a.bin' "$TMP/err" || fail "--verify did not list the stale path"
grep -q 'reference/r.bin' "$TMP/err" && fail "--verify reported a real edit as stale"
[ "$(git -C "$TMP/c5c" status --porcelain | wc -l)" = 2 ] || fail "--verify changed the index"
bash "$TOOL" hydrate "$TMP/c5c" > "$TMP/out" || fail "hydrate did not repair a stale index: $(cat "$TMP/out")"
grep -q 'rewriting them from the index' "$TMP/out" || fail "hydrate did not report the repair"
grep -q '0 pointers, index current' "$TMP/out" || fail "hydrate did not report a current index"
[ "$(git -C "$TMP/c5c" status --porcelain)" = " M reference/r.bin" ] || fail "after repair, status is not exactly the real edit: $(git -C "$TMP/c5c" status --porcelain)"
[ "$(cat "$TMP/c5c/reference/r.bin")" = "edited" ] || fail "the repair discarded a real edit"

stale_clone "$TMP/c5d"
touch "$TMP/c5d/.git/index.lock"
if bash "$TOOL" hydrate "$TMP/c5d" >/dev/null 2>"$TMP/err"; then fail "hydrate passed while the index stayed locked"; fi
grep -q 'index entries are stale' "$TMP/err" || fail "a locked index was not reported as stale"
rm -f "$TMP/c5d/.git/index.lock"
echo "ok 5b - a stale index: verify reports it, hydrate repairs it, real edits survive, a held lock fails"

# --- 6. session end to end, including the upload -------------------------------
pointer_clone "$TMP/c6"
bash "$TOOL" session "$TMP/c6" > "$TMP/out" || fail "session failed: $(cat "$TMP/out")"
grep -q '0 pointers' "$TMP/out" || fail "session reported no hydration"
echo "new payload" > "$TMP/c6/assets/new.bin"
git -C "$TMP/c6" add assets/new.bin && git -C "$TMP/c6" commit -qm new
oid="$(git -C "$TMP/c6" lfs ls-files --long -I 'assets/new.bin' | awk '{print $1}')"
[ ${#oid} -eq 64 ] || fail "new.bin is not LFS-tracked"
git -C "$TMP/c6" push -q origin HEAD:main >/dev/null 2>&1 || fail "push failed"
[ -f "$ORIGIN/lfs/objects/${oid:0:2}/${oid:2:2}/$oid" ] || fail "push did not upload the LFS object"
echo "ok 6 - session hydrates a pointer clone, and a push uploads new objects"

# --- 7. usage ------------------------------------------------------------------
for args in "" "bogus" "hydrate --nope" "pre-push-hook --verify" "credential-fallback --include=x"; do
  set +e; # shellcheck disable=SC2086  # word splitting is the point
  bash "$TOOL" $args >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = 2 ] || fail "'$args' exited $rc, expected 2"
done
echo "ok 7 - usage errors exit 2"
