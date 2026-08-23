#!/usr/bin/env bash
# Focused regression coverage for the bounded Markdown-link rewriter grammar.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rewrite="$root/Tools/rewrite-moved-markdown-links.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$work/repo/docs/work/kaizen" "$work/repo/docs/operations" "$work/repo/assets"
fixture="$work/repo/staged.md"
cat > "$fixture" <<'EOF'
# Entry

[guide](../../operations/guide.md?view=full#install "Guide title")
![logo](<../../assets/logo.png#mark>)
[guide-ref]: ../../operations/guide.md?view=full#install "Reference title"
[web](https://example.com) [fragment](#part)
`[code](../../../missing.md)`
EOF
before="$work/before.md"
cp "$fixture" "$before"
bash "$rewrite" "$work/repo" docs/work/kaizen/journal.md \
  docs/work/kaizen/journal/2026-01/entry.md "$fixture" || fail "supported fixture was refused"
grep -Fq '[guide](../../../../operations/guide.md?view=full#install "Guide title")' "$fixture" \
  || fail "inline destination was not rebased with query/fragment/title preserved"
grep -Fq '![logo](<../../../../assets/logo.png#mark>)' "$fixture" || fail "image target was not rebased"
grep -Fq '[guide-ref]: ../../../../operations/guide.md?view=full#install "Reference title"' "$fixture" \
  || fail "reference target was not rebased"
grep -Fq '[web](https://example.com) [fragment](#part)' "$fixture" || fail "URI or fragment changed"
# shellcheck disable=SC2016 # Markdown backticks are literal fixture bytes.
grep -Fq '`[code](../../../missing.md)`' "$fixture" || fail "inline-code target changed"
diff -u <(sed -E 's#\.\./\.\./operations/#TARGET/#g; s#\.\./\.\./assets/#TARGET/#g' "$before") \
  <(sed -E 's#\.\./\.\./\.\./\.\./operations/#TARGET/#g; s#\.\./\.\./\.\./\.\./assets/#TARGET/#g' "$fixture") \
  > /dev/null || fail "rewriter changed bytes outside link targets"
echo "ok 1 - rebases supported targets and preserves all other bytes"

for case_name in parenthesized multiline; do
  candidate="$work/$case_name.md"
  if [[ "$case_name" == parenthesized ]]; then
    printf '[bad](../../../operations/(guide).md)\n' > "$candidate"
  else
    printf '[bad](../../../operations/\nguide.md)\n' > "$candidate"
  fi
  before_sum="$(sha256sum "$candidate")"
  set +e
  output="$(bash "$rewrite" "$work/repo" docs/work/kaizen/journal.md docs/work/kaizen/journal/2026-01/entry.md "$candidate" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "$case_name syntax was accepted"
  grep -q 'docs/work/kaizen/journal.md:1' <<< "$output" || fail "$case_name refusal did not name source and line: $output"
  [[ "$(sha256sum "$candidate")" == "$before_sum" ]] || fail "$case_name refusal modified its input"
done
echo "ok 2 - refuses ambiguous syntax atomically with file and line"

echo "all moved-link rewrite tests passed"
