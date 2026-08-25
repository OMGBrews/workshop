#!/usr/bin/env bash
# docs-only-diff.sh — is the committed diff from <base> to HEAD confined to this
# repo's declared prose surface?
#
# Usage: bash workshop/Tools/docs-only-diff.sh <base-ref-or-sha>   (from the repo root)
#
# Exit 0  -> docs-only. Every changed path is inside the surface this repo declares,
#            and the diff is non-empty. The repo's expensive checks do not read those
#            paths, so their outcome is decided by the diff alone: take the docs lane.
# Exit 1  -> NOT docs-only, or the diff is empty. Run the full verification suite.
# Exit 2  -> cannot decide — no declaration, a bad ref, not a git repo. Callers MUST
#            treat this as "not docs-only". Never as a pass.
#
# This is the single definition of the docs-only predicate. Every consumer runs it,
# so no two ends can drift into disagreeing about what "docs-only" means.
#
# WHY THE SURFACE IS DECLARED PER REPO, AND NOT BUILT IN
#
# The predicate is only ever as safe as one claim: *no check in this repo reads these
# paths*. That is a fact about a particular repo's checks, not about the word "docs" —
# a `docs/` directory inside a package a test suite walks is read, and exempting it
# would skip a check that genuinely applies. So there is no default surface and no
# fallback: a repo with no declaration gets exit 2, which is the safe answer rather
# than a guess made on its behalf. Declaring the surface is the act of making that
# claim deliberately, in the same file that lists the checks it makes inapplicable.
#
# The declaration lives between sentinels in the repo's definition-of-done.md —
# docs/work/definition-of-done.md:
#
#     <!-- DOCS-ONLY:BEGIN — paths no check in this repo reads. DO NOT REMOVE. -->
#     docs/
#     README.md
#     <!-- DOCS-ONLY:END -->
#
# A line ending in `/` is a directory prefix; any other line is an exact path.
# Globs are deliberately unsupported — `*.md` reads as harmless and quietly covers
# a fixture a test loads. Anything that is not a plain path is a hard error, not a
# skipped line, because a silently-ignored entry makes the surface smaller than it
# reads and the failure is invisible.

set -euo pipefail

base="${1:-}"
if [ -z "$base" ]; then
  echo "usage: docs-only-diff.sh <base-ref-or-sha>   (run from the repo root)" >&2
  exit 2
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "not a git repository — cannot classify the diff" >&2
  exit 2
fi

dod="docs/work/definition-of-done.md"
if [ ! -f "$dod" ]; then
  echo "no definition-of-done.md found (looked in docs/work/)" >&2
  echo "docs-only: cannot decide" >&2
  exit 2
fi

# Sentinels anchored to the start of a line, so prose naming one cannot open the
# block; exit at the first END, so a second pair later cannot re-open it.
surface="$(awk '/^<!-- DOCS-ONLY:END/{exit} p && NF; /^<!-- DOCS-ONLY:BEGIN/{p=1}' "$dod")"

if [ -z "$surface" ]; then
  echo "$dod declares no docs-only surface, so this repo has no docs fast lane." >&2
  echo "That is a valid state: it means every check is presumed to read every path." >&2
  echo "docs-only: cannot decide" >&2
  exit 2
fi

# A malformed entry must stop the run. Skipping it would shrink the surface
# silently, and a smaller surface produces a *correct-looking* "not docs-only" —
# the failure would never be noticed, and the declaration would rot unread.
if bad="$(printf '%s\n' "$surface" | grep -nE '[][*?]|^/|^\.\./|(^|/)\.\.(/|$)' || true)"; [ -n "$bad" ]; then
  echo "$dod — malformed line(s) in the DOCS-ONLY block; each must be a plain" >&2
  echo "repo-relative path, no globs and no traversal:" >&2
  printf '%s\n' "$bad" | sed 's/^/    /' >&2
  exit 2
fi

# --no-renames is load-bearing, not a style choice. With rename detection on (the
# default), --name-only reports a rename as ONLY its destination path, so
# `git mv src/code.py docs/moved.md` deletes a source file while the diff reads as
# pure prose — a false green that skips the full suite. Disabling it reports the rename
# as its delete + add pair, so the source path is seen.
if ! files="$(git diff --no-renames --name-only "$base" HEAD 2>/dev/null)"; then
  echo "could not diff '$base'..HEAD — is '$base' a valid ref?" >&2
  echo "docs-only: cannot decide" >&2
  exit 2
fi

echo "Declared prose surface (from $dod):"
printf '%s\n' "$surface" | sed 's/^/  /'
echo "Changed files ($base..HEAD):"
printf '%s\n' "${files:-  (none)}" | sed 's/^/  /'

# An empty diff is deliberately NOT docs-only. There is nothing to fast-lane, and
# the safe default for "I cannot see a change" is the full verification suite.
if [ -z "$files" ]; then
  echo "docs-only: no (empty diff)"
  exit 1
fi

outside=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  matched=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      */) case "$f" in "$p"*) matched=1 ;; esac ;;
      *)  [ "$f" = "$p" ] && matched=1 ;;
    esac
    [ -n "$matched" ] && break
  done <<<"$surface"
  [ -n "$matched" ] || outside="${outside}${f}"$'\n'
done <<<"$files"

if [ -n "$outside" ]; then
  echo "Outside the declared surface:"
  printf '%s' "$outside" | sed 's/^/  /'
  echo "docs-only: no"
  exit 1
fi

echo "docs-only: yes"
exit 0
