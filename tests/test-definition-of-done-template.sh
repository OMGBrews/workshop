#!/usr/bin/env bash
# Tests for docs/templates/definition-of-done.md — the canonical shape of a
# repository's docs/work/definition-of-done.md, as docs/definition-of-done-schema.md
# defines it.
#
# The template is what every consumer copies, so the assertions are about what
# a copy does in a real repository rather than about the template's prose. A
# page in the template's shape, with the DOCS-ONLY block filled in under
# "### Docs-only surface", is what Tools/docs-only-diff.sh must read — exit 0
# with the declared surface echoed back — and the same page with the block
# removed is what it must refuse to decide on (exit 2). The docs/work
# conformance checker's clauses 6 and 7 are asserted on the same page, so the
# new shape is proven against the readers that exist today, not only against
# the predicate.
#
# The page is derived from the template by deleting its guidance comments, the
# way an author does, rather than written out here: a hand-written fixture would
# keep passing after the template drifted.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$WORKSHOP_ROOT/docs/templates/definition-of-done.md"
SCHEMA="$WORKSHOP_ROOT/docs/definition-of-done-schema.md"
PREDICATE="$WORKSHOP_ROOT/Tools/docs-only-diff.sh"
CONFORMANCE="$WORKSHOP_ROOT/Tools/check-docs-work-conformance.sh"

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in "$TEMPLATE" "$SCHEMA" "$PREDICATE" "$CONFORMANCE"; do
  [ -f "$f" ] || { echo "PRECONDITION FAILED: $f is missing" >&2; exit 1; }
done

# --- 1. the template carries the schema's six sections, in order --------------
expected_h2='## Repository profile
## Pre-commit feedback
## Landing requirements
## Release requirements
## Deployment requirements
## Known gaps'
actual_h2="$(grep '^## ' "$TEMPLATE")"
if [ "$actual_h2" = "$expected_h2" ]; then
  ok "template carries exactly the six level-two headings, in order"
else
  fail "template level-two headings differ from the schema's six"
  printf '%s\n' "$actual_h2" | sed 's/^/    /'
fi

# The schema's numbered list names the same six, as inline code, in the same order.
schema_h2="$(grep -E '^[0-9]+\. `## ' "$SCHEMA" | sed -e 's/^[0-9]*\. `//' -e 's/`$//')"
if [ "$schema_h2" = "$expected_h2" ]; then
  ok "schema names the same six headings in the same order"
else
  fail "schema's heading list differs from the template's"
  printf '%s\n' "$schema_h2" | sed 's/^/    /'
fi

# --- 2. the DOCS-ONLY block has its defined position ---------------------------
line_of() { grep -n -m1 "$1" "$TEMPLATE" | cut -d: -f1; }
landing=$(line_of '^## Landing requirements$')
docs_only=$(line_of '^### Docs-only surface$')
begin=$(line_of '^<!-- DOCS-ONLY:BEGIN')
end=$(line_of '^<!-- DOCS-ONLY:END')
release=$(line_of '^## Release requirements$')
if [ -n "$landing" ] && [ -n "$docs_only" ] && [ -n "$begin" ] && [ -n "$end" ] && [ -n "$release" ] \
   && [ "$landing" -lt "$docs_only" ] && [ "$docs_only" -lt "$begin" ] \
   && [ "$begin" -lt "$end" ] && [ "$end" -lt "$release" ]; then
  ok "DOCS-ONLY sentinels sit under '### Docs-only surface', last in landing requirements, at column zero"
else
  fail "DOCS-ONLY block is not in its defined position (landing=$landing h3=$docs_only begin=$begin end=$end release=$release)"
fi
# No level-three heading may follow the docs-only one inside the section.
if awk -v a="$docs_only" -v b="$release" 'NR>a && NR<b && /^### /{found=1} END{exit found?1:0}' "$TEMPLATE"; then
  ok "no further level-three heading follows the docs-only surface inside landing requirements"
else
  fail "a level-three heading follows '### Docs-only surface' before '## Release requirements'"
fi
# Nothing but blank lines between the sentinels: the predicate reads every
# non-blank line there as a path, so guidance there would shrink the surface.
between="$(awk '/^<!-- DOCS-ONLY:END/{exit} p && NF; /^<!-- DOCS-ONLY:BEGIN/{p=1}' "$TEMPLATE")"
if [ -z "$between" ]; then
  ok "nothing sits between the template's sentinels"
else
  fail "the template carries text between its DOCS-ONLY sentinels:"
  printf '%s\n' "$between" | sed 's/^/    /'
fi

# --- 3. a page derived from the template, the way an author derives one -------
# Guidance comments go; the two DOCS-ONLY sentinels stay; the surface is filled.
strip_guidance() {  # <template> -> stdout
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"<!--(?! DOCS-ONLY:).*?-->", "", text, flags=re.S)
sys.stdout.write(re.sub(r"\n{3,}", "\n\n", text))
PY
}
PAGE="$TMP/page.md"
strip_guidance "$TEMPLATE" | sed '/^<!-- DOCS-ONLY:BEGIN/a docs/' >"$PAGE"
if grep -q '<!--' <(grep -v '^<!-- DOCS-ONLY:' "$PAGE"); then
  fail "derived page still carries a guidance comment"
else
  ok "derived page keeps only the two sentinels"
fi

# --- 4. the predicate reads the block at that position -------------------------
REPO="$TMP/scratch"
git_q() { git -C "$REPO" "$@" >/dev/null 2>&1; }
mkdir -p "$REPO/docs/work" "$REPO/src"
git_q init -b main
git_q config user.email test@example.com
git_q config user.name "Template Test"
cp "$PAGE" "$REPO/docs/work/definition-of-done.md"
echo "# guide" >"$REPO/docs/guide.md"
echo "echo hi" >"$REPO/src/app.sh"
git_q add -A
git_q commit -m "base"
BASE="$(git -C "$REPO" rev-parse HEAD)"
echo "more" >>"$REPO/docs/guide.md"
git_q add -A
git_q commit -m "prose only"

rc=0
out=$( (cd "$REPO" && bash "$PREDICATE" "$BASE") 2>&1 ) || rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -Fxq '  docs/' \
   && printf '%s\n' "$out" | grep -Fxq 'docs-only: yes'; then
  ok "docs-only-diff.sh exits 0 and echoes the declared surface for a page in the template's shape"
else
  fail "docs-only-diff.sh on the template-shaped page: exit $rc, wanted 0 with '  docs/' and 'docs-only: yes'"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# The negative: the same page with the block replaced by the no-surface sentence.
sed -e '/^<!-- DOCS-ONLY:BEGIN/,/^<!-- DOCS-ONLY:END/d' "$PAGE" \
  | sed -e '/^### Docs-only surface$/a \
\
No docs-only surface is declared; every check is presumed to read every path.' \
  >"$REPO/docs/work/definition-of-done.md"
rc=0
out=$( (cd "$REPO" && bash "$PREDICATE" "$BASE") 2>&1 ) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -Fq 'declares no docs-only surface'; then
  ok "the same page without the block cannot decide (exit 2)"
else
  fail "docs-only-diff.sh without the block: exit $rc, wanted 2 with 'declares no docs-only surface'"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# --- 5. today's readers still pass on the new shape ----------------------------
# Clause 6 wants a level-one heading and content; clause 7 reports the block.
cp "$PAGE" "$REPO/docs/work/definition-of-done.md"
mkdir -p "$REPO/docs/work/tasks/now" "$REPO/docs/work/tasks/soon" \
         "$REPO/docs/work/tasks/later" "$REPO/docs/work/tasks/finalized" \
         "$REPO/docs/work/tasks/never"
rc=0
out=$(bash "$CONFORMANCE" "$REPO" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -Eq '(^| )6 .*docs/work/definition-of-done.md \(1 heading' \
   && printf '%s\n' "$out" | grep -Fq 'DOCS-ONLY block present'; then
  ok "check-docs-work-conformance.sh clauses 6 and 7 pass on the template-shaped page"
else
  fail "check-docs-work-conformance.sh on the template-shaped page: exit $rc, wanted 0 with clause 6 ok and clause 7 reporting the block"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures assertion(s) failed" >&2
  exit 1
fi
echo "all definition-of-done template assertions passed"
