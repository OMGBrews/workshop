#!/usr/bin/env bash
#
# normalize-remote.sh — reduce a git remote URL (or a declaration line) to a
# canonical lowercase `owner/repo`, so `/ship` can compare the two.
#
# Phase 1 of the ship skill decides whether a declared parent is already in this
# session by comparing a repo's `origin` URL against the `owner/repo` lines in a
# child's consumed-by declaration — docs/work/consumed-by.md. Both sides go through THIS
# script, which is what
# makes the comparison a string equality that holds across:
#
#   - SCP form        git@github.com:OMGBrews/plunk.git
#   - ssh://          ssh://git@github.com/OMGBrews/plunk.git
#   - https://        https://github.com/OMGBrews/plunk.git
#   - the cloud git proxy, which inserts a path segment ahead of the pair:
#                     http://local_proxy@127.0.0.1:41337/git/OMGBrews/plunk
#   - a bare declaration line, unchanged apart from case:  OMGBrews/plunk
#
# Two live failures it exists to prevent (found-in-words-cms cloud ship,
# 2026-07-29): the old inline sed stripped a prefix rather than matching the
# trailing pair, so the proxy's `/git/` segment survived and NOTHING matched;
# and `add_repo` reports a lowercased owner (`omgbrews/...`) against declarations
# written `OMGBrews/...`, which broke the same match independently. Every
# declared parent was then classified "not in this session" and planned for the
# full unattached-parent cycle — so a parent that DID mount the child in-session
# would get a second, competing pointer-bump PR for the same change.
#
# Matching the trailing pair rather than stripping known prefixes is deliberate:
# the bug class here is a URL shape nobody enumerated, and a prefix-stripper has
# to be taught each one. This has to be taught none.
#
# Usage:
#   normalize-remote.sh <url-or-line> [<url-or-line> ...]
#   normalize-remote.sh < file-of-lines        # one per line; blanks skipped
#   git -C <repo> remote get-url origin | normalize-remote.sh
#
# Output: one `owner/repo` per input, lowercased, on stdout.
# Exit:   0 if every input normalized; 1 (with the offender on stderr) if any
#         did not. It never prints a value it could not reduce to a pair --
#         emitting the input unchanged is how a normalizer silently feeds an
#         unmatchable string into a comparison that then reports "no match".
set -euo pipefail

normalize_one() { # <raw>
  local raw="$1" out
  out="$(printf '%s' "$raw" \
    | sed -E 's#\.git/?$##; s#/+$##; s#.*[:/]([^/:]+/[^/]+)$#\1#' \
    | tr '[:upper:]' '[:lower:]')"

  # Positive assertion on the artifact, not an equality a no-op also satisfies:
  # unmatched input survives the sed untouched, so the shape check below is the
  # only thing separating "normalized" from "passed straight through".
  if ! printf '%s' "$out" | grep -Eqx '[a-z0-9._-]+/[a-z0-9._-]+'; then
    echo "normalize-remote: cannot reduce to owner/repo: $raw" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

status=0

if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    normalize_one "$arg" || status=1
  done
else
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "${line//[[:space:]]/}" ] || continue
    normalize_one "$line" || status=1
  done
fi

exit "$status"
