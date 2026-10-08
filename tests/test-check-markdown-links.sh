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
printf '[guide](docs/guide.md) ![logo](assets/logo.png) [ref]: docs/guide.md\n`[ignored](missing.md)`\n```text\n[ignored](missing.md)\n```\n[web](https://example.com) [part](#here)\n' > "$work/good/README.md"
git -C "$work/good" init -q
git -C "$work/good" add -A
git -C "$work/good" -c user.name=test -c user.email=test@example.com commit -qm fixture
bash "$check" "$work/good" > "$work/good.log" 2>&1 || { cat "$work/good.log"; fail "valid links failed"; }
echo "ok 1 - relative links pass; code, URIs, and fragments are ignored"

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
printf 'present\n' > "$work/module/target.md"
git -C "$work/module" add target.md
git -C "$work/module" -c user.name=test -c user.email=test@example.com commit -qm module
module_sha="$(git -C "$work/module" rev-parse HEAD)"
mkdir -p "$work/boundary/docs"
printf '[escape](../../outside.md)\n[valid](../vendor/populated/target.md)\n[broken](../vendor/populated/missing.md)\n' \
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
printf 'ok\n' > "$work/encoded/my docs/guide é.md"
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
  grep -Fxq "stale .markdown-links-skip entry matches no tracked Markdown source: $stale" "$work/stale.log" \
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

echo "all markdown-link tests passed"
