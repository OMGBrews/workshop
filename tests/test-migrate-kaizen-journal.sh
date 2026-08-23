#!/usr/bin/env bash
# Tests for Tools/migrate-kaizen-journal.sh.
#
# The script's contract, asserted here:
#   1. splits a journal into journal/YYYY-MM/YYYY-MM-DD-<slug>.md, rewriting the
#      dated heading to `# <title>` and preserving body bytes except for
#      relative Markdown targets rebased to the same destination;
#   2. files each entry by the date in its OWN heading, not by file order — real
#      journals grow out-of-order tails from merges and bulk backfills;
#   3. ignores the specimen heading inside the template's HTML comment (the
#      scaffold ships one, so every fresh repo carries this decoy);
#   4. slugs hostile titles (backticks, punctuation, multibyte) to
#      [a-z0-9-] capped at 60 bytes on a hyphen boundary, with an
#      all-punctuation title falling back to "entry";
#   5. separates same-day entries whose titles slugify identically with -2;
#   6. is idempotent — a migrated repo is reported as such and left untouched;
#   7. refuses a `## ` heading it cannot file, leaves the source byte-identical,
#      creates no directory, and exits non-zero. Silently dropping an entry
#      would destroy it, and the run would still look orderly;
#   8. converts a freshly-scaffolded (entry-less) repo to empty directories;
#   9. splits real patterns out of patterns.md;
#  10. exits non-zero on a docs/work/kaizen with neither documents nor directories;
#  11. rebases journal and pattern links before moving either document, and the
#      shared link checker distinguishes the broken verbatim negative control.
set -euo pipefail

DEVTOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE="$DEVTOOLS_ROOT/Tools/migrate-kaizen-journal.sh"
CHECK_LINKS="$DEVTOOLS_ROOT/Tools/check-markdown-links.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

new_repo() { # <name> -> prints repo root
  local root="$TMP/$1"
  mkdir -p "$root/docs/work/kaizen"
  printf '%s\n' "$root"
}

# The preamble every real journal carries: title, intro, and a format comment
# that itself contains a `## YYYY-MM-DD — ...` specimen heading.
preamble() {
  cat <<'EOF'
# Kaizen Journal

A running log of friction, errors, and lessons. Newest entries first.

---

<!--
Prepend new entries immediately below this comment, newest first, using:

## YYYY-MM-DD — [short title]

**Context**: What we were trying to do
**Action**: Concrete change made or to be made
-->

EOF
}

entry() { # <date> <title> <body-marker>
  printf '## %s — %s\n\n**Context**: ctx-%s\n**What happened**: what\n**Friction**: fr\n**Lesson**: le\n**Action**: ac\n\n' \
    "$1" "$2" "$3"
}

# --- 1. splits a journal, rewrites headings, deletes the source --------------
R="$(new_repo basic)"
{ preamble
  entry 2026-07-27 'The judge scored empty output' a
  # shellcheck disable=SC2016  # the backticks are literal title text, on purpose
  entry 2026-07-24 'Plain `uv sync` uninstalled the extras' b
  entry 2026-06-11 'Documented architecture was unwired' c
} > "$R/docs/work/kaizen/journal.md"
out="$(bash "$MIGRATE" "$R" 2>&1)" || fail "migrate failed: $out"

f1="$R/docs/work/kaizen/journal/2026-07/2026-07-27-the-judge-scored-empty-output.md"
[[ -f "$f1" ]] || fail "expected $f1; got: $(find "$R/docs/work/kaizen/journal" -name '*.md' | sort)"
[[ "$(head -1 "$f1")" == '# The judge scored empty output' ]] \
  || fail "heading not rewritten to '# <title>': $(head -1 "$f1")"
grep -q '^\*\*Context\*\*: ctx-a$' "$f1" || fail "body not copied verbatim"
[[ "$(grep -c '^\*\*' "$f1")" == 5 ]] || fail "expected 5 bold fields, got $(grep -c '^\*\*' "$f1")"
[[ -f "$R/docs/work/kaizen/journal/2026-07/2026-07-24-plain-uv-sync-uninstalled-the-extras.md" ]] \
  || fail "backticked title not slugged as expected"
[[ -e "$R/docs/work/kaizen/journal.md" ]] && fail "journal.md survived a successful migration"
[[ -f "$R/docs/work/kaizen/journal/README.md" ]] || fail "journal/README.md not created"
echo "ok 1 - splits entries, rewrites headings, removes the source"

# --- 2. each entry filed by its own heading date, not file order ------------
# Mirrors the real anomaly: a descending block followed by an ascending tail.
R="$(new_repo out_of_order)"
{ preamble
  entry 2026-07-27 'Newest of the descending block' a
  entry 2026-06-11 'Oldest of the descending block' b
  entry 2026-07-12 'First of the appended ascending tail' c
  entry 2026-07-25 'Last of the appended ascending tail' d
} > "$R/docs/work/kaizen/journal.md"
bash "$MIGRATE" "$R" > /dev/null 2>&1 || fail "migrate failed on the out-of-order journal"
while IFS= read -r f; do
  base="$(basename "$f")"
  [[ "$(basename "$(dirname "$f")")" == "${base:0:7}" ]] \
    || fail "entry filed under the wrong month: $f"
done < <(find "$R/docs/work/kaizen/journal" -name '2026-*.md')
[[ -f "$R/docs/work/kaizen/journal/2026-06/2026-06-11-oldest-of-the-descending-block.md" ]] \
  || fail "the June entry did not land in 2026-06/"
[[ "$(find "$R/docs/work/kaizen/journal" -name '2026-*.md' | wc -l)" == 4 ]] || fail "expected 4 entries"
echo "ok 2 - files every entry by its own heading date"

# --- 3. the specimen heading inside the HTML comment is not an entry --------
R="$(new_repo decoy)"
{ preamble; entry 2026-05-05 'Only real entry' a; } > "$R/docs/work/kaizen/journal.md"
bash "$MIGRATE" "$R" > /dev/null 2>&1 || fail "migrate failed on the decoy fixture"
n="$(find "$R/docs/work/kaizen/journal" -name '*.md' ! -name README.md | wc -l)"
[[ "$n" == 1 ]] || fail "expected 1 entry, got $n — the commented specimen heading was extracted"
echo "ok 3 - ignores the specimen heading inside the HTML comment"

# --- 4. hostile titles slug cleanly and stay within the cap -----------------
R="$(new_repo slugs)"
long_title='A constraint enforced downstream was never taught upstream; five drifted definitions because none was the source of truth'
{ preamble
  entry 2026-05-01 '!!! ???' a
  entry 2026-05-02 '/ship ran gates: "then" pushed 5× — oops' b
  entry 2026-05-03 "$long_title" c
} > "$R/docs/work/kaizen/journal.md"
bash "$MIGRATE" "$R" > /dev/null 2>&1 || fail "migrate failed on hostile titles"
[[ -f "$R/docs/work/kaizen/journal/2026-05/2026-05-01-entry.md" ]] \
  || fail "all-punctuation title did not fall back to 'entry'"
while IFS= read -r f; do
  base="$(basename "$f" .md)"
  slug="${base:11}"
  [[ "$slug" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail "slug is not clean: $slug"
  (( ${#slug} <= 60 )) || fail "slug exceeds the 60-byte cap (${#slug}): $slug"
done < <(find "$R/docs/work/kaizen/journal" -name '2026-*.md')
# The truncated slug must end on a whole word from the title, not a fragment.
long_slug="$(basename "$(find "$R/docs/work/kaizen/journal" -name '2026-05-03-*.md')" .md)"
last_word="${long_slug##*-}"
printf '%s' "$long_title" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '\n' | grep -qx "$last_word" \
  || fail "long title was cut mid-word (trailing fragment '$last_word'): $long_slug"
echo "ok 4 - slugs hostile titles cleanly, caps at 60 on a word boundary"

# --- 5. same-day identical slugs are separated, not overwritten -------------
R="$(new_repo collision)"
{ preamble
  entry 2026-05-02 'Foo bar' first
  entry 2026-05-02 'Foo, bar' second
} > "$R/docs/work/kaizen/journal.md"
bash "$MIGRATE" "$R" > /dev/null 2>&1 || fail "migrate failed on the collision fixture"
a="$R/docs/work/kaizen/journal/2026-05/2026-05-02-foo-bar.md"
b="$R/docs/work/kaizen/journal/2026-05/2026-05-02-foo-bar-2.md"
[[ -f "$a" && -f "$b" ]] || fail "colliding slugs were not separated: $(ls "$R/docs/work/kaizen/journal/2026-05")"
grep -q 'ctx-first' "$a" || fail "first entry's body missing"
grep -q 'ctx-second' "$b" || fail "second entry's body missing — it overwrote the first"
echo "ok 5 - separates same-day entries whose slugs collide"

# --- 6. idempotent ----------------------------------------------------------
# The collision fixture has a journal but never had a patterns.md, so exactly
# one document reports as already migrated.
before="$(find "$R/docs/work/kaizen" -type f -exec md5sum {} + | sort)"
out="$(bash "$MIGRATE" "$R" 2>&1)" || fail "second run failed: $out"
echo "$out" | grep -q 'already-migrated 1' || fail "second run did not report the journal migrated: $out"
echo "$out" | grep -q 'migrated 0' || fail "second run re-migrated: $out"
[[ "$(find "$R/docs/work/kaizen" -type f -exec md5sum {} + | sort)" == "$before" ]] \
  || fail "second run modified the tree"
echo "ok 6 - idempotent"

# --- 7. an unfileable heading is refused, loudly and non-destructively ------
R="$(new_repo bad_heading)"
{ preamble
  entry 2026-05-01 'A fine entry' a
  printf '## Not a dated heading\n\n**Context**: orphan\n\n'
} > "$R/docs/work/kaizen/journal.md"
sum_before="$(md5sum < "$R/docs/work/kaizen/journal.md")"
set +e
out="$(bash "$MIGRATE" "$R" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "exited 0 despite an unfileable heading — a caller cannot tell"
echo "$out" | grep -q 'Not a dated heading' || fail "did not name the offending heading: $out"
[[ "$(md5sum < "$R/docs/work/kaizen/journal.md")" == "$sum_before" ]] || fail "refused journal was modified"
[[ -d "$R/docs/work/kaizen/journal" ]] && fail "refused run still created journal/ — writes are not staged"
echo "ok 7 - refuses an unfileable heading, leaves the source untouched, exits non-zero"

# --- 8. a freshly-scaffolded repo converts to empty directories -------------
R="$(new_repo scaffold)"
preamble > "$R/docs/work/kaizen/journal.md"
printf '# Kaizen patterns\n\nRecurring themes.\n\n---\n\n<!--\n## [Pattern name]\n\n**Pattern**: shape\n-->\n' \
  > "$R/docs/work/kaizen/patterns.md"
out="$(bash "$MIGRATE" "$R" 2>&1)" || fail "migrate failed on a fresh scaffold: $out"
[[ -f "$R/docs/work/kaizen/journal/README.md" ]] || fail "journal/README.md missing"
[[ -f "$R/docs/work/kaizen/patterns/README.md" ]] || fail "patterns/README.md missing"
[[ "$(find "$R/docs/work/kaizen/journal" "$R/docs/work/kaizen/patterns" -name '*.md' ! -name README.md | wc -l)" == 0 ]] \
  || fail "the commented specimens were extracted as content"
[[ -e "$R/docs/work/kaizen/journal.md" || -e "$R/docs/work/kaizen/patterns.md" ]] && fail "sources survived"
echo "ok 8 - converts a fresh scaffold to empty directories"

# --- 9. real patterns are split out ----------------------------------------
R="$(new_repo patterns)"
preamble > "$R/docs/work/kaizen/journal.md"
{ printf '# Kaizen patterns\n\nRecurring themes.\n\n---\n\n'
  printf '## Verification that cannot fail\n\n**Pattern**: checks a no-op satisfies.\n\n'
  printf '## Stale cached refs\n\n**Pattern**: sizing work off origin/main.\n\n'
} > "$R/docs/work/kaizen/patterns.md"
bash "$MIGRATE" "$R" > /dev/null 2>&1 || fail "migrate failed on real patterns"
p="$R/docs/work/kaizen/patterns/verification-that-cannot-fail.md"
[[ -f "$p" ]] || fail "pattern not split: $(ls "$R/docs/work/kaizen/patterns")"
[[ "$(head -1 "$p")" == '# Verification that cannot fail' ]] || fail "pattern heading not rewritten"
[[ -f "$R/docs/work/kaizen/patterns/stale-cached-refs.md" ]] || fail "second pattern missing"
echo "ok 9 - splits real patterns into one file each"

# --- 10. a docs/work/kaizen with nothing to migrate is an error -------------
R="$(new_repo empty)"
set +e
out="$(bash "$MIGRATE" "$R" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "exited 0 on a docs/work/kaizen with no documents and no directories"
echo "ok 10 - exits non-zero when there is nothing to migrate"

# --- 11. moved bodies retain their resolved Markdown destinations ------------
R="$(new_repo link_rewrite)"
mkdir -p "$R/docs/targets"
printf '# Kaizen\n' > "$R/docs/work/kaizen/README.md"
printf 'journal target\n' > "$R/docs/targets/journal.md"
printf 'pattern target\n' > "$R/docs/targets/pattern.md"
{ preamble
  entry 2026-07-27 'Journal link destination' link
  printf '[journal target](../../targets/journal.md)\n'
} > "$R/docs/work/kaizen/journal.md"
printf '# Kaizen patterns\n\n## Pattern link destination\n\n[pattern target](../../targets/pattern.md)\n' \
  > "$R/docs/work/kaizen/patterns.md"
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" -c user.name=test -c user.email=test@example.com commit -qm source

# A verbatim deep copy reproduces the llmkit-dev class: the original target is
# valid from kaizen/, but broken from journal/YYYY-MM/. It must be tracked, or
# the checker would never inspect it.
negative="$R/docs/work/kaizen/journal/2026-07/2026-07-27-journal-link-destination.md"
mkdir -p "$(dirname "$negative")"
printf '# Journal link destination\n\n[journal target](../../targets/journal.md)\n' > "$negative"
git -C "$R" add -A
git -C "$R" -c user.name=test -c user.email=test@example.com commit -qm negative
set +e
negative_output="$(bash "$CHECK_LINKS" "$R" 2>&1)"
negative_rc=$?
set -e
[[ "$negative_rc" -eq 1 ]] || fail "verbatim negative control exited $negative_rc, expected 1: $negative_output"
grep -q '2026-07-27-journal-link-destination.md -> ../../targets/journal.md' <<< "$negative_output" \
  || fail "negative control did not name the broken source and target: $negative_output"
rm -f "$negative"
git -C "$R" add -u
git -C "$R" -c user.name=test -c user.email=test@example.com commit -qm remove-negative

bash "$MIGRATE" "$R" > /dev/null 2>&1 || fail "migrate failed on link fixture"
git -C "$R" add -A
check_output="$(bash "$CHECK_LINKS" "$R" 2>&1)" || fail "rewritten migration did not pass the shared link checker: $check_output"
journal_link="$R/docs/work/kaizen/journal/2026-07/2026-07-27-journal-link-destination.md"
pattern_link="$R/docs/work/kaizen/patterns/pattern-link-destination.md"
grep -q '(../../../../targets/journal.md)' "$journal_link" || fail "journal target was not rebased two levels"
grep -q '(../../../targets/pattern.md)' "$pattern_link" || fail "pattern target was not rebased one level"
[[ -f "$(dirname "$journal_link")/../../../../targets/journal.md" ]] || fail "journal target no longer resolves"
[[ -f "$(dirname "$pattern_link")/../../../targets/pattern.md" ]] || fail "pattern target no longer resolves"
echo "ok 11 - rewrites moved links; tracked verbatim negative control fails the checker"
