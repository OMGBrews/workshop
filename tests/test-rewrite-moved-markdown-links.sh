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

midline="$work/midline.md"
printf 'See [guide](../../operations/guide.md) and ![logo](<../../assets/logo.png>) here.\n' > "$midline"
bash "$rewrite" "$work/repo" docs/work/kaizen/journal.md \
  docs/work/kaizen/journal/2026-01/entry.md "$midline" || fail "mid-line links were refused"
grep -Fxq 'See [guide](../../../../operations/guide.md) and ![logo](<../../../../assets/logo.png>) here.' "$midline" \
  || { cat "$midline"; fail "mid-line links were not rebased cleanly"; }
echo "ok 3 - links that do not start the line are rebased without copying stray bytes"

footnote="$work/footnote.md"
printf 'Text[^1].\n\n[^1]:\n[^2]: See [guide](../../operations/guide.md).\n' > "$footnote"
bash "$rewrite" "$work/repo" docs/work/kaizen/journal.md \
  docs/work/kaizen/journal/2026-01/entry.md "$footnote" || fail "footnote definitions were refused"
grep -Fxq '[^1]:' "$footnote" || fail "empty footnote definition changed"
grep -Fxq '[^2]: See [guide](../../../../operations/guide.md).' "$footnote" \
  || fail "link inside footnote text was not rebased"
echo "ok 4 - footnote definitions are text, not reference definitions"

echo "all moved-link rewrite tests passed"

cat > "$work/fences.md" <<'EOF'
````markdown
```
[example](missing.md)
~~~
[example](missing.md)
```` trailing text
[example](missing.md)
````
~~~
```
[example](missing.md)
~~~
[real](target.md#heading?literal)
EOF
bash "$root/Tools/rewrite-moved-markdown-links.sh" --extract "$work/fences.md" > "$work/fences.out"
printf '13\ttarget.md#heading?literal\n' > "$work/fences.expected"
cmp "$work/fences.expected" "$work/fences.out" || fail 'nested fence extraction leaked links'
echo 'ok - fence delimiter, length and trailing text respected'

cat > "$work/container-fences.md" <<'EOF'
> ```markdown
> [ignored](missing.md)
> ```

- ```markdown
  [ignored](missing.md)
  ```
[real](target.md)
EOF
bash "$rewrite" --extract "$work/container-fences.md" > "$work/container-fences.out"
printf '8\ttarget.md\n' > "$work/container-fences.expected"
cmp "$work/container-fences.expected" "$work/container-fences.out" || fail 'container fence extraction leaked links'
echo 'ok - blockquote and list fences exclude example links'

cat > "$work/container-end.md" <<'EOF'
> ```
> example

[broken](missing.md)

- ```
  example

[broken](missing.md)
EOF
bash "$rewrite" --extract "$work/container-end.md" > "$work/container-end.out"
printf '4\tmissing.md\n9\tmissing.md\n' > "$work/container-end.expected"
cmp "$work/container-end.expected" "$work/container-end.out" || fail 'container end hid real links'
echo 'ok - leaving a container ends an unclosed fence'

# --extract-batch: one process, the same grammar, per-file line numbers and fence
# state, an empty file keeping its argument position, and a stop at the first
# unparseable file that names it and leaves earlier files complete.
printf '```\n[hidden](a.md)\n' > "$work/batch-open-fence.md"
: > "$work/batch-empty.md"
printf 'x\n[one](<b c.md>) [two](d.md)\n' > "$work/batch-links.md"
printf '[bad](e(f).md)\n' > "$work/batch-bad.md"
printf '[after](g.md)\n' > "$work/batch-after.md"
bash "$rewrite" --extract-batch "$work/batch-open-fence.md" "$work/batch-empty.md" \
  "$work/batch-links.md" > "$work/batch.out" || fail 'batch extraction refused supported files'
printf '3\t2\tb c.md\n3\t2\td.md\n' > "$work/batch.expected"
cmp "$work/batch.expected" "$work/batch.out" || fail 'batch extraction lost position, line or fence reset'
for single in batch-open-fence batch-links; do
  bash "$rewrite" --extract "$work/$single.md" > "$work/$single.single"
  bash "$rewrite" --extract-batch "$work/$single.md" | cut -f2- > "$work/$single.batched"
  cmp "$work/$single.single" "$work/$single.batched" || fail "batch and single extraction disagree on $single"
done
set +e
bash "$rewrite" --extract-batch "$work/batch-links.md" "$work/batch-bad.md" "$work/batch-after.md" \
  > "$work/batch-bad.out" 2> "$work/batch-bad.err"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "unparseable batch exited $rc, expected 1"
grep -Fq "$work/batch-bad.md:1: unsupported Markdown link syntax" "$work/batch-bad.err" \
  || fail 'unparseable batch file was not named with its line'
[[ "$(tail -n 1 "$work/batch-bad.out")" == $'2\terror' ]] || fail 'unparseable batch file position was not reported'
grep -q $'^1\t2\td.md$' "$work/batch-bad.out" || fail 'files before the unparseable one lost their records'
if grep -q $'^3\t' "$work/batch-bad.out"; then fail 'batch continued past the unparseable file'; fi
echo 'ok - batch extraction matches single-file extraction and stops at the first unparseable file'
