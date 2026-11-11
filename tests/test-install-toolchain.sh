#!/usr/bin/env bash
# Exercise install-toolchain.sh offline: downloads are served from fixtures by a
# curl stand-in, so the digest gate and the install layout are tested without
# the network and without touching /usr/local.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Tools/devcontainer/install-toolchain.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# ── Fixtures: archives shaped like the upstream releases ────────────────────
mkdir -p "$WORK/fixture/git-lfs-3.8.1" "$WORK/fixture/python/bin"
cat > "$WORK/fixture/git-lfs-3.8.1/git-lfs" <<'STUB'
#!/bin/sh
echo "git-lfs/3.8.1 (fixture)"
STUB
cat > "$WORK/fixture/python/bin/python3" <<'STUB'
#!/bin/sh
[ "$1" = "--version" ] && echo "Python 3.13.18"
exit 0
STUB
chmod +x "$WORK/fixture/git-lfs-3.8.1/git-lfs" "$WORK/fixture/python/bin/python3"
tar -czf "$WORK/git-lfs.tar.gz" -C "$WORK/fixture" git-lfs-3.8.1
tar -czf "$WORK/python.tar.gz" -C "$WORK/fixture" python
LFS_SHA="$(sha256sum "$WORK/git-lfs.tar.gz" | cut -d' ' -f1)"
PY_SHA="$(sha256sum "$WORK/python.tar.gz" | cut -d' ' -f1)"
WRONG_SHA="$(printf 'x' | sha256sum | cut -d' ' -f1)"

export TOOLCHAIN_PREFIX="$WORK/prefix"
# shellcheck disable=SC1090,SC1091  # linted on its own by `make lint`
source "$SCRIPT"

# Stand-in for curl: record the URL, then write the matching fixture to the
# path given with --output.
curl() {
    local out="" url="" arg
    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
            --output) out="$2"; shift 2 ;;
            http*) url="$arg"; shift ;;
            *) shift ;;
        esac
    done
    echo "$url" >> "$WORK/curl.log"
    case "$url" in
        *git-lfs*) cp "$WORK/git-lfs.tar.gz" "$out" ;;
        *cpython*) cp "$WORK/python.tar.gz" "$out" ;;
        *) return 22 ;;
    esac
}

# ── 1. The shipped pins are well formed ─────────────────────────────────────
for pin in git-lfs/amd64 git-lfs/arm64 python-3.13/amd64 python-3.13/arm64; do
    value="$(pin_sha256 "${pin%/*}" "${pin#*/}")"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || fail "pin $pin is not a SHA-256: '$value'"
done
[[ "$RUBY_BUILD_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "RUBY_BUILD_COMMIT is not a commit ID"
[ -z "$(pin_sha256 git-lfs riscv64)" ] || fail "an unpinned architecture returned a digest"

# ── 2. A wrong digest installs nothing ──────────────────────────────────────
# shellcheck disable=SC2317,SC2329  # called by the sourced script
pin_sha256() { echo "$WRONG_SHA"; }
mkdir -p "$WORK/dl"
if (install_git_lfs amd64 "$WORK/dl") 2> "$WORK/err"; then
    fail "install_git_lfs succeeded with a mismatched digest"
fi
grep -q "SHA-256 mismatch" "$WORK/err" || fail "mismatch not reported: $(cat "$WORK/err")"
[ ! -e "$WORK/prefix/bin/git-lfs" ] || fail "git-lfs was installed despite a mismatched digest"
[ -z "$(ls -A "$WORK/dl")" ] || fail "the rejected download was left behind"

# ── 3. A missing digest is refused, not treated as unverified-but-fine ──────
# shellcheck disable=SC2317,SC2329  # called by the sourced script
pin_sha256() { :; }
if (install_git_lfs amd64 "$WORK/dl") 2> "$WORK/err"; then
    fail "install_git_lfs succeeded with no pinned digest"
fi
grep -q "no pinned SHA-256" "$WORK/err" || fail "missing pin not reported: $(cat "$WORK/err")"
[ ! -e "$WORK/prefix/bin/git-lfs" ] || fail "git-lfs was installed with no pinned digest"

# ── 4. Matching digests install the documented layout ───────────────────────
pin_sha256() {
    case "$1" in
        git-lfs) echo "$LFS_SHA" ;;
        python-*) echo "$PY_SHA" ;;
    esac
}
install_git_lfs amd64 "$WORK/dl"
[ "$("$WORK/prefix/bin/git-lfs" version)" = "git-lfs/3.8.1 (fixture)" ] \
    || fail "git-lfs not installed at prefix/bin"

install_python 3.13 arm64 "$WORK/dl" ""
[ "$(readlink "$WORK/prefix/python/current")" = "3.13.18" ] || fail "python/current does not name the version"
[ -x "$WORK/prefix/python/3.13.18/bin/python3" ] || fail "python tree missing"
[ "$("$WORK/prefix/bin/python3" --version)" = "Python 3.13.18" ] || fail "prefix/bin/python3 not linked"
grep -q 'aarch64-unknown-linux-gnu-install_only' "$WORK/curl.log" || fail "arm64 did not request the aarch64 asset"
grep -q '%2B' "$WORK/curl.log" || fail "the '+' in the Python asset name was not percent-encoded"

# A second run finds both tools present and downloads nothing.
: > "$WORK/curl.log"
install_git_lfs amd64 "$WORK/dl"
install_python 3.13 arm64 "$WORK/dl" ""
[ ! -s "$WORK/curl.log" ] || fail "an already-installed tool was downloaded again"

# ── 5. Bad requests fail before any download ────────────────────────────────
: > "$WORK/curl.log"
for args in "--python 9.9" "--ruby 3.3.1" "--python" "--bogus"; do
    # shellcheck disable=SC2086  # word splitting is the point
    if (main $args) > /dev/null 2> "$WORK/err"; then
        fail "main accepted: $args"
    fi
    grep -q '^install-toolchain: ' "$WORK/err" || fail "no diagnostic for: $args"
done
[ ! -s "$WORK/curl.log" ] || fail "a rejected request still downloaded something"

echo "install-toolchain: all checks passed"
