#!/usr/bin/env bash
# Regression coverage for Workshop's standalone Markdown-link check.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$root/Tools/check-markdown-links.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$work/good/docs" "$work/good/assets"
printf 'ok\n' > "$work/good/docs/guide.md"
printf 'image\n' > "$work/good/assets/logo.png"
# shellcheck disable=SC2016 # Markdown backticks and parentheses are literal fixture bytes.
printf '[guide](docs/guide.md) ![logo](assets/logo.png) [ref]: docs/guide.md\n`[ignored](missing.md)`\n```text\n[ignored](missing.md)\n```\n[web](https://example.com) [part](#here)\n# Here\n' > "$work/good/README.md"
git -C "$work/good" init -q
git -C "$work/good" add -A
git -C "$work/good" -c user.name=test -c user.email=test@example.com commit -qm fixture
bash "$check" "$work/good" > "$work/good.log" 2>&1 || { cat "$work/good.log"; fail "valid links failed"; }
echo "ok 1 - relative and same-file links pass; code ignored and URIs named"

printf '[gone](docs/missing.md)\n' > "$work/good/broken.md"
git -C "$work/good" add broken.md
git -C "$work/good" -c user.name=test -c user.email=test@example.com commit -qm broken
if bash "$check" "$work/good" > "$work/broken.log" 2>&1; then
  fail "broken relative link passed"
fi
grep -q 'broken.md -> docs/missing.md' "$work/broken.log" || { cat "$work/broken.log"; fail "broken link was not named"; }
echo "ok 2 - broken relative links fail by source and target"

# A populated submodule is checked like any other visible directory; a missing
# target inside it must still fail. Repo-escaping targets are deliberately named
# skips instead of probing arbitrary parent paths.
mkdir -p "$work/module"
git -C "$work/module" init -q
printf '# Present\n' > "$work/module/target.md"
git -C "$work/module" add target.md
git -C "$work/module" -c user.name=test -c user.email=test@example.com commit -qm module
module_sha="$(git -C "$work/module" rev-parse HEAD)"
mkdir -p "$work/boundary/docs"
printf '[escape](../../outside.md)\n[valid](../vendor/populated/target.md#present)\n[missing-anchor](../vendor/populated/target.md#absent)\n[broken](../vendor/populated/missing.md)\n' \
  > "$work/boundary/docs/guide.md"
git -C "$work/boundary" init -q
git -C "$work/boundary" -c protocol.file.allow=always submodule add -q "$work/module" vendor/populated
git -C "$work/boundary" add -A
git -C "$work/boundary" -c user.name=test -c user.email=test@example.com commit -qm boundary
set +e
bash "$check" "$work/boundary" > "$work/boundary.log" 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]] || { cat "$work/boundary.log"; fail "populated submodule broken target exited $rc, expected 1"; }
grep -q 'skipped Markdown link escaping repository: docs/guide.md -> ../../outside.md' "$work/boundary.log" \
  || { cat "$work/boundary.log"; fail "repo escape was not named"; }
grep -q 'broken Markdown link: docs/guide.md -> ../vendor/populated/missing.md' "$work/boundary.log" \
  || { cat "$work/boundary.log"; fail "populated submodule broken target was not checked"; }
grep -q 'missing Markdown anchor: docs/guide.md -> ../vendor/populated/target.md#absent' "$work/boundary.log" || fail 'populated anchor not checked'
echo "ok 3 - escaping targets skip; populated submodule targets are checked"

# Build an unpopulated submodule entry without using `git -C vendor/...`: that
# command can walk up into the superproject and lie about the mount existing.
mkdir -p "$work/unavailable/docs"
printf '[unavailable](../vendor/unavailable/target.md)\n' > "$work/unavailable/docs/guide.md"
git -C "$work/unavailable" init -q
cat > "$work/unavailable/.gitmodules" <<EOF
[submodule "vendor/unavailable"]
  path = vendor/unavailable
  url = $work/module
EOF
git -C "$work/unavailable" add .gitmodules docs/guide.md
git -C "$work/unavailable" update-index --add --cacheinfo "160000,$module_sha,vendor/unavailable"
git -C "$work/unavailable" -c user.name=test -c user.email=test@example.com commit -qm unavailable
bash "$check" "$work/unavailable" > "$work/unavailable.log" 2>&1 \
  || { cat "$work/unavailable.log"; fail "unavailable submodule target failed"; }
grep -q 'skipped Markdown link into unavailable submodule: docs/guide.md -> ../vendor/unavailable/target.md' "$work/unavailable.log" \
  || { cat "$work/unavailable.log"; fail "unavailable submodule was not named"; }
echo "ok 4 - unavailable submodule targets skip and are named"

commit_all() { git -C "$1" add -A && git -C "$1" -c user.name=test -c user.email=test@example.com commit -qm "$2"; }
run_check() { # <repo> <log> -> sets rc
  set +e
  bash "$check" "$1" > "$2" 2>&1
  rc=$?
  set -e
}

# Targets are percent-decoded before the existence test; the extractor is not.
mkdir -p "$work/encoded/my docs"
printf '# X\n' > "$work/encoded/my docs/guide é.md"
printf '[ok](my%%20docs/guide%%20%%C3%%A9.md) [frag](my%%20docs/guide%%20%%C3%%A9.md#x)\n' > "$work/encoded/README.md"
git -C "$work/encoded" init -q
commit_all "$work/encoded" encoded
run_check "$work/encoded" "$work/encoded.log"
[[ "$rc" -eq 0 ]] || { cat "$work/encoded.log"; fail "existing percent-encoded target exited $rc"; }
printf '[gone](my%%20docs/missing%%20file.md)\n' > "$work/encoded/broken.md"
commit_all "$work/encoded" broken
run_check "$work/encoded" "$work/encoded-broken.log"
[[ "$rc" -eq 1 ]] || { cat "$work/encoded-broken.log"; fail "missing percent-encoded target exited $rc, expected 1"; }
grep -q 'broken Markdown link: broken.md -> my%20docs/missing%20file.md' "$work/encoded-broken.log" \
  || { cat "$work/encoded-broken.log"; fail "missing encoded target was not named as written"; }
echo "ok 5 - percent-encoded targets are decoded; missing ones still fail"

# Footnote definitions are not link definitions, even empty ones; links in
# their text are still checked.
mkdir -p "$work/footnote"
printf 'Text[^1] and[^note].\n\n[^1]:\n[^note]: See [missing](absent.md).\n' > "$work/footnote/README.md"
git -C "$work/footnote" init -q
commit_all "$work/footnote" footnote
run_check "$work/footnote" "$work/footnote.log"
[[ "$rc" -eq 1 ]] || { cat "$work/footnote.log"; fail "footnote fixture exited $rc, expected 1"; }
grep -q 'broken Markdown link: README.md -> absent.md' "$work/footnote.log" \
  || { cat "$work/footnote.log"; fail "link inside footnote text was not checked"; }
echo "ok 6 - footnote definitions are not parsed as link definitions"

# Listed files and directories are skipped and named; a stale entry fails.
mkdir -p "$work/skip/frozen/old" "$work/skip/vendor"
printf '[gone](missing.md)\n' > "$work/skip/frozen/a.md"
printf '[gone](missing.md)\n' > "$work/skip/frozen/old/b.md"
printf '[gone](missing.md)\n' > "$work/skip/vendor/README.md"
printf '[ok](frozen/a.md)\n' > "$work/skip/README.md"
printf '# Frozen records: never edited\nfrozen/\n\n  vendor/README.md  \n' > "$work/skip/.markdown-links-skip"
git -C "$work/skip" init -q
commit_all "$work/skip" skip
run_check "$work/skip" "$work/skip.log"
[[ "$rc" -eq 0 ]] || { cat "$work/skip.log"; fail "skip-listed sources exited $rc"; }
for listed in frozen/a.md frozen/old/b.md vendor/README.md; do
  grep -Fxq "skipped Markdown source (listed in .markdown-links-skip): $listed" "$work/skip.log" \
    || { cat "$work/skip.log"; fail "skipped source $listed was not named"; }
done
grep -q '^Markdown links valid; 3 source' "$work/skip.log" || { cat "$work/skip.log"; fail "skip total wrong"; }
printf 'gone/\nfrozen\n' >> "$work/skip/.markdown-links-skip"
run_check "$work/skip" "$work/stale.log"
[[ "$rc" -eq 1 ]] || { cat "$work/stale.log"; fail "stale skip entries exited $rc, expected 1"; }
for stale in gone/ frozen; do
  grep -Fxq "stale .markdown-links-skip entry matches no visible Markdown source: $stale" "$work/stale.log" \
    || { cat "$work/stale.log"; fail "stale entry $stale was not named"; }
done
echo "ok 7 - listed files and directories skip by name; stale entries fail"

for bad in 'frozen/*.md' '/frozen/a.md' 'frozen/../vendor/' '../outside.md'; do
  printf '%s\n' "$bad" > "$work/skip/.markdown-links-skip"
  run_check "$work/skip" "$work/bad-skip.log"
  [[ "$rc" -eq 2 ]] || { cat "$work/bad-skip.log"; fail "skip entry '$bad' exited $rc, expected 2"; }
  grep -Fq "unsupported entry (no wildcards, absolute paths, or .. segments): $bad" "$work/bad-skip.log" \
    || { cat "$work/bad-skip.log"; fail "unsupported entry '$bad' was not named"; }
done
echo "ok 8 - wildcard, absolute, and .. skip entries are refused"

# An unparseable source exits 2, but the rest of the repository is still checked.
mkdir -p "$work/unparsed"
printf '[wiki](https://en.wikipedia.org/wiki/A_(b))\n' > "$work/unparsed/a.md"
printf '[gone](missing.md)\n' > "$work/unparsed/z.md"
git -C "$work/unparsed" init -q
commit_all "$work/unparsed" unparsed
run_check "$work/unparsed" "$work/unparsed.log"
[[ "$rc" -eq 2 ]] || { cat "$work/unparsed.log"; fail "unparseable source exited $rc, expected 2"; }
grep -q 'a.md:1: unsupported Markdown link syntax' "$work/unparsed.log" \
  || { cat "$work/unparsed.log"; fail "unparseable source was not named"; }
grep -q 'broken Markdown link: z.md -> missing.md' "$work/unparsed.log" \
  || { cat "$work/unparsed.log"; fail "sources after an unparseable one were not checked"; }
echo "ok 9 - an unparseable source exits 2 without hiding the rest of the repository"


mkdir -p "$work/anchors"
cat > "$work/anchors/target.md" <<'EOF'
# Foo
# Foo
# Foo-1
# Foo
# *Hello* `Code` [link](somewhere) &amp; Café!
Setext heading
--------------
# Under_score
<a id="Exact.ID"></a><a name="Named"></a>
````markdown
# Fenced
<a id="fake"></a>
```
~~~
[ignored](missing.md)
````
    # Indented
    <a id="indented"></a>
<!-- <a id="comment"></a> -->
`<a id="inline"></a>`
<pre><a id="html-code"></a></pre>
EOF
# Keep unsupported example links out of extraction while exercising target parsing.
cat > "$work/anchors/.markdown-links-skip" <<'EOF'
target.md
EOF
printf '# Hash\n' > "$work/anchors/hash#question?.md"
printf 'asset\n' > "$work/anchors/asset.txt"
cat > "$work/anchors/README.md" <<'EOF'
# Local
[local](#local)
[duplicate](target.md#foo-1-1) [collision](target.md#foo-2)
[rendered](target.md#hello-code-link--caf%C3%A9)
[setext](target.md#setext-heading) [underscore](target.md#under_score)
[explicit](target.md#Exact.ID) [named](target.md#Named)
[encoded](hash%23question%3F.md?view=1#hash)
[top](target.md#) [asset](asset.txt#anything) [uri](urn:example:anything)
EOF
git -C "$work/anchors" init -q
commit_all "$work/anchors" anchors
run_check "$work/anchors" "$work/anchors.log"
[[ "$rc" -eq 0 ]] || { cat "$work/anchors.log"; fail 'rendered heading and explicit anchors failed'; }
grep -q 'skipped non-Markdown fragment: README.md -> asset.txt#anything' "$work/anchors.log" || fail 'asset skip unnamed'
grep -q 'skipped URI Markdown link: README.md -> urn:example:anything' "$work/anchors.log" || fail 'URI skip unnamed'
echo 'ok 10 - rendered headings, collisions, explicit anchors, encoded delimiters and named skips'

for destination in 'target.md#absent' '#absent' 'target.md#fenced' 'target.md#fake' 'target.md#indented' 'target.md#comment' 'target.md#inline' 'target.md#html-code' 'target.md#foo%0Amissing' 'target.md#foo%0A'; do
  printf '[broken](%s)\n' "$destination" > "$work/anchors/broken.md"
  git -C "$work/anchors" add broken.md
  run_check "$work/anchors" "$work/missing-anchor.log"
  [[ "$rc" -eq 1 ]] || { cat "$work/missing-anchor.log"; fail "missing anchor $destination exited $rc"; }
  grep -Fq "missing Markdown anchor: broken.md -> $destination" "$work/missing-anchor.log" || fail 'missing fragment diagnostic lost destination'
done
printf '[broken](absent.txt#anything)\n' > "$work/anchors/broken.md"
run_check "$work/anchors" "$work/missing-asset.log"
[[ "$rc" -eq 1 ]] || fail 'non-Markdown existence bypassed'
echo 'ok 11 - absent same/cross-file and code anchors fail; non-Markdown existence remains checked'

printf '\377' > "$work/anchors/target.md"
printf '[broken](target.md#foo)\n' > "$work/anchors/broken.md"
run_check "$work/anchors" "$work/parser-error.log"
[[ "$rc" -eq 2 ]] || fail "parser error exited $rc"
grep -q 'anchor parsing failed:.*target.md' "$work/parser-error.log" || fail 'parser error unnamed'
echo 'ok 12 - parser errors exit 2'


# Working-tree sources and targets share one view; every probe leaves the index
# byte-for-byte unchanged, including staged entries unrelated to live content.
mkdir -p "$work/dirty/docs"
git -C "$work/dirty" init -q
printf '# Gone\n' > "$work/dirty/docs/gone.md"
printf '# Home\n' > "$work/dirty/README.md"
commit_all "$work/dirty" dirty
assert_dirty_check() { # <expected status>
  git -C "$work/dirty" ls-files --stage -z > "$work/index.before"
  run_check "$work/dirty" "$work/dirty.log"
  [[ "$rc" -eq "$1" ]] || { cat "$work/dirty.log"; fail "dirty view exited $rc, expected $1"; }
  git -C "$work/dirty" ls-files --stage -z > "$work/index.after"
  cmp "$work/index.before" "$work/index.after" || fail 'checker modified index'
}
rm "$work/dirty/docs/gone.md"
assert_dirty_check 0
printf '[gone](docs/gone.md)\n' > "$work/dirty/README.md"
assert_dirty_check 1
grep -Fq 'broken Markdown link: README.md -> docs/gone.md' "$work/dirty.log" || fail 'deleted target not named'
printf '# Home\n' > "$work/dirty/README.md"
printf '[broken](absent.md)\n' > "$work/dirty/new.md"
assert_dirty_check 1
grep -Fq 'broken Markdown link: new.md -> absent.md' "$work/dirty.log" || fail 'untracked source not scanned'
printf '# New\n' > "$work/dirty/new.md"
printf '[new](new.md)\n' > "$work/dirty/README.md"
assert_dirty_check 0
mv "$work/dirty/new.md" "$work/dirty/renamed.md"
assert_dirty_check 1
printf '[new](renamed.md)\n' > "$work/dirty/README.md"
assert_dirty_check 0
printf 'ignored/\n' > "$work/dirty/.gitignore"
mkdir "$work/dirty/ignored"
printf '[broken](absent.md)\n' > "$work/dirty/ignored/source.md"
assert_dirty_check 0
printf '[ignored](ignored/source.md)\n' > "$work/dirty/README.md"
assert_dirty_check 1
grep -Fq 'README.md -> ignored/source.md' "$work/dirty.log" || fail 'ignored target leaked into view'
echo 'ok 13 - unstaged deletion, inbound links, new sources and targets, rename and ignore handling preserve index'

# NUL-safe Git discovery is only half the contract: relative normalization and
# percent decoding must retain newline directory components and trailing bytes.
printf '# Home\n' > "$work/dirty/README.md"
newline_dir=$'space dir\nnext\n'
mkdir -p "$work/dirty/$newline_dir"
printf '# Target\n' > "$work/dirty/$newline_dir/target.md"
printf 'asset\n' > "$work/dirty/$newline_dir/asset"$'\n'
printf '[relative](target.md#target) [trailing](asset%%0A) [parent](../README.md#home)\n' > "$work/dirty/$newline_dir/source.md"
printf '[dir](space%%20dir%%0Anext%%0A/target.md#target)\n' >> "$work/dirty/README.md"
assert_dirty_check 0
printf '[missing](missing.md)\n' > "$work/dirty/$newline_dir/source.md"
assert_dirty_check 1
grep -Fq 'source.md -> missing.md' "$work/dirty.log" || fail 'newline-bearing source missed'
printf '[relative](target.md#target)\n' > "$work/dirty/$newline_dir/source.md"
printf '[missing](absent.md)\n' > "$work/dirty/$newline_dir/symlink-target"
ln -s symlink-target "$work/dirty/$newline_dir/link.md"
assert_dirty_check 0
grep -Fq 'skipped symlink Markdown source:' "$work/dirty.log" || fail 'source symlink skip lost'
echo 'ok 14 - newline directories, trailing-newline targets and symlink source skips'

# Child Markdown is target material, not an implicit extra source collection.
printf '[bad](absent.md)\n' > "$work/boundary/vendor/populated/new.md"
printf '# Edited child\n' > "$work/boundary/vendor/populated/target.md"
printf '[child](../vendor/populated/target.md#edited-child)\n' > "$work/boundary/docs/guide.md"
run_check "$work/boundary" "$work/child-dirty.log"
[[ "$rc" -eq 0 ]] || { cat "$work/child-dirty.log"; fail 'visible child edits or parent-only source boundary lost'; }
echo 'ok 15 - child edits supply targets without scanning child sources'

# Explicit ignored independent repositories contribute targets, never sources.
mkdir -p "$work/registered/external"
git -C "$work/registered" init -q
printf 'external/\n' > "$work/registered/.gitignore"
printf '[target](external/target.md#present)\n' > "$work/registered/README.md"
git -C "$work/registered" add .gitignore README.md
git -C "$work/registered/external" init -q
printf '# Present\n[not a parent source](missing.md)\n' > "$work/registered/external/target.md"
git -C "$work/registered/external" add target.md
if bash "$check" "$work/registered" > "$work/registered-before.log" 2>&1; then
  fail 'ignored independent repository was implicitly included'
fi
bash "$check" "$work/registered" --target-repository external > "$work/registered.log" 2>&1 \
  || { cat "$work/registered.log"; fail 'explicit independent target failed'; }
printf '# Changed\n' > "$work/registered/external/target.md"
if bash "$check" "$work/registered" --target-repository external > "$work/registered-anchor.log" 2>&1; then
  fail 'missing anchor in independent target passed'
fi
grep -q 'missing Markdown anchor:' "$work/registered-anchor.log" || fail 'independent anchor was not checked'
rm "$work/registered/external/target.md"
if bash "$check" "$work/registered" --target-repository external > "$work/registered-missing.log" 2>&1; then
  fail 'missing file in independent target passed'
fi
grep -q 'broken Markdown link:' "$work/registered-missing.log" || fail 'independent missing file was not checked'
echo 'ok - explicit independent repositories supply checked targets without adding sources'

# Repositories nested inside a target still resolve; an unpopulated submodule
# nested inside a target remains a named skip, not a broken link.
mkdir -p "$work/leaf"
git -C "$work/leaf" init -q
printf '# Leaf\n' > "$work/leaf/leaf.md"
git -C "$work/leaf" add leaf.md
git -C "$work/leaf" -c user.name=test -c user.email=test@example.com commit -qm leaf
printf '# Present\n' > "$work/registered/external/target.md"
git -C "$work/registered/external" add target.md
git -C "$work/registered/external" -c protocol.file.allow=always submodule add -q "$work/leaf" nested
git -C "$work/registered/external" -c protocol.file.allow=always submodule add -q "$work/leaf" absent
git -C "$work/registered/external" -c user.name=test -c user.email=test@example.com commit -qm nested
git -C "$work/registered/external" submodule deinit -q -f absent
printf '[target](external/target.md#present) [leaf](external/nested/leaf.md#leaf) [absent](external/absent/leaf.md)\n' \
  > "$work/registered/README.md"
bash "$check" "$work/registered" --target-repository external > "$work/registered-nested.log" 2>&1 \
  || { cat "$work/registered-nested.log"; fail 'link into a repository nested inside a target failed'; }
grep -Fq 'skipped Markdown link into unavailable submodule: README.md -> external/absent/leaf.md' \
  "$work/registered-nested.log" || { cat "$work/registered-nested.log"; fail 'unpopulated nested submodule was not a named skip'; }
printf '[leaf](external/nested/leaf.md#gone)\n' > "$work/registered/README.md"
if bash "$check" "$work/registered" --target-repository external > "$work/registered-nested-anchor.log" 2>&1; then
  fail 'missing anchor in a repository nested inside a target passed'
fi
grep -q 'missing Markdown anchor:' "$work/registered-nested-anchor.log" || fail 'nested target anchor was not checked'
echo 'ok - repositories nested inside targets resolve and unpopulated ones are named skips'

echo 'all markdown-link tests passed'
