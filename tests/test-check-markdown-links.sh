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

echo "all markdown-link tests passed"
