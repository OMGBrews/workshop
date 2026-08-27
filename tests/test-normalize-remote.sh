#!/usr/bin/env bash
# Tests for Tools/normalize-remote.sh — the remote/declaration normalizer that
# /ship Phase 1 step 3 uses to decide whether a declared parent is already in
# this session.
#
# The contract, asserted here:
#   1. every URL shape a real remote presents reduces to `owner/repo`,
#      the cloud git proxy's `/git/`-segment form included;
#   2. casing never decides a match — `add_repo` returns a lowercased owner
#      while declarations are written `OMGBrews/...`;
#   3. a bare declaration line passes through, so BOTH sides of the comparison
#      can go through this same script;
#   4. input it cannot reduce to a pair fails loudly instead of being echoed
#      back as if normalized;
#   5. whatever real remotes this machine has around this checkout all normalize
#      (when present).
#
# TEST 4 is the one that matters most: the bug this script replaced did not
# throw, it returned a plausible-looking string that then matched nothing.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NORM="$WORKSHOP_ROOT/Tools/normalize-remote.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

expect() { # <input> <expected>
  local got
  got="$(bash "$NORM" "$1")" || fail "exited non-zero on: $1"
  [ "$got" = "$2" ] || fail "$1 -> '$got', expected '$2'"
}

# --- 1. every URL shape a real remote presents -----------------------------
expect "git@github.com:OMGBrews/plunk.git"                              "omgbrews/plunk"
expect "ssh://git@github.com/OMGBrews/plunk.git"                        "omgbrews/plunk"
expect "https://github.com/OMGBrews/plunk.git"                          "omgbrews/plunk"
expect "https://github.com/OMGBrews/plunk"                              "omgbrews/plunk"
expect "https://github.com/OMGBrews/shared.git/"                        "omgbrews/shared"
expect "https://github.com/foiassist/pia-maker.git"                     "foiassist/pia-maker"
echo "ok 1 - the git@/ssh/https shapes reduce to owner/repo"

# --- 1b. the cloud git proxy form (the live 2026-07-29 failure) ------------
# The old inline sed stripped `https?://[^/]+/`, which ate the host and port and
# left `git/OMGBrews/found-in-words-cms` — a string no declaration line matches.
expect "http://local_proxy@127.0.0.1:41337/git/OMGBrews/found-in-words-cms" \
       "omgbrews/found-in-words-cms"
expect "http://local_proxy@127.0.0.1:8080/git/OMGBrews/shared"           "omgbrews/shared"
echo "ok 1b - the cloud proxy's inserted path segment does not survive"

# --- 2. casing never decides a match ---------------------------------------
# add_repo reported `omgbrews/found-in-words`; the declaration says `OMGBrews/...`.
a="$(bash "$NORM" "http://local_proxy@127.0.0.1:41337/git/omgbrews/found-in-words")"
b="$(bash "$NORM" "OMGBrews/found-in-words")"
[ "$a" = "$b" ] || fail "casing decided the match: '$a' vs '$b'"
echo "ok 2 - a lowercased owner still matches a mixed-case declaration"

# --- 3. a declaration line passes through ----------------------------------
expect "OMGBrews/found-in-words"                                        "omgbrews/found-in-words"
expect "omgbrews/workshop-dev"                                          "omgbrews/workshop-dev"
echo "ok 3 - both sides of the comparison can use this script"

# --- 4. unreducible input fails loudly, and prints nothing on stdout -------
# A normalizer that echoes what it could not parse is the original bug in a new
# costume: the caller compares a garbage string, gets no match, and reports the
# parent as absent.
for bad in "not-a-url" "" "https://github.com/" "ssh://git@github.com/lonely"; do
  if out="$(bash "$NORM" "$bad" 2>/dev/null)"; then
    fail "accepted unreducible input '$bad' -> '$out'"
  fi
  [ -z "${out:-}" ] || fail "printed '$out' on stdout while rejecting '$bad'"
done
echo "ok 4 - unreducible input exits non-zero with an empty stdout"

# --- 4b. one bad line does not suppress the good ones ----------------------
out="$(printf 'OMGBrews/plunk\nnot-a-url\nOMGBrews/shared\n' | bash "$NORM" 2>/dev/null || true)"
[ "$out" = "omgbrews/plunk
omgbrews/shared" ] || fail "stdin batch dropped good lines: '$out'"
echo "ok 4b - a rejected line does not discard the rest of the batch"

# --- 5. the real remotes around this checkout, where there are any ---------
# The walk starts one level above this repository, so it finds sibling clones in a
# workspace and the consuming repo when Workshop is mounted inside one. It finds
# nothing in a bare or cloud checkout, and says so — a silent skip here would look
# identical to a pass.
checked=0
ws="$(cd "$WORKSHOP_ROOT/.." && pwd)"
while IFS= read -r gitdir; do
  repo="$(dirname "$gitdir")"
  url="$(git -C "$repo" remote get-url origin 2>/dev/null)" || continue
  [ -n "$url" ] || continue
  bash "$NORM" "$url" >/dev/null || fail "real remote did not normalize: $url ($repo)"
  checked=$((checked + 1))
done < <(find "$ws" -maxdepth 4 -name .git -not -path '*/node_modules/*' 2>/dev/null)

if [ "$checked" -eq 0 ]; then
  echo "ok 5 - SKIPPED: no sibling clones around this checkout (0 real remotes checked)"
else
  echo "ok 5 - $checked real remote(s) normalized"
fi

echo "all normalize-remote tests passed"
