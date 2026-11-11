#!/bin/bash
# Language runtimes and Git LFS for a devcontainer image, from pinned releases.
# Runs as root during the Docker build, before the USER switch.
#
# Usage in a Dockerfile, as early as possible (directly after FROM):
#   COPY workshop/Tools/devcontainer/install-toolchain.sh /tmp/install-toolchain.sh
#   RUN bash /tmp/install-toolchain.sh --python 3.13
#
#   install-toolchain.sh [--python <minor>] [--ruby <minor>] [--no-git-lfs]
#                        [--user <name>]
#
# Git LFS is installed unless --no-git-lfs is given: build/setup.sh marks the
# LFS filter as required, so an image without the binary cannot check out an
# LFS repository. Python and Ruby are installed only when asked for.
#
# Why this exists instead of the Dev Container features for the same tools.
# The git-lfs, python, and ruby features verify their downloads with GPG keys
# fetched from public keyservers at build time. When keyserver.ubuntu.com is
# unreachable the build fails, and the fallback keyserver strips identities
# from keys whose owners have not opted in, so it cannot stand in. Features
# also layer after the Dockerfile, so any change to a file the Dockerfile
# COPYs reinstalls every feature. This script removes both exposures:
#
#   - Integrity comes from SHA-256 digests (or a commit ID) written in this
#     file, checked against what was downloaded. No keyserver is contacted.
#   - It is one file with no siblings, so a Dockerfile can COPY and RUN it
#     before anything else. Its layer is rebuilt only when this file changes.
#
# Network hosts used: github.com release downloads for Git LFS, Python, and
# ruby-build; for Ruby also the distribution's package mirror (build
# dependencies) and cache.ruby-lang.org (source, verified by ruby-build's own
# recorded digest).
#
# Layout. Everything lands under /usr/local, which is on the default PATH of
# every shell, including a non-interactive `docker exec`:
#
#   /usr/local/bin/git-lfs
#   /usr/local/python/<version>/      with /usr/local/python/current -> <version>
#   /usr/local/ruby/<version>/        with /usr/local/ruby/current -> <version>
#   /usr/local/bin/{python3,python,pip,pip3,ruby,gem,bundle,...} -> the above
#
# The interpreter trees are owned by the image's non-root user (--user, or
# the account with UID 1000), so `pip install` and `gem install` work without
# sudo. Executables those commands add land in the tree's own bin directory;
# a Dockerfile that wants them on PATH adds, after the RUN above:
#   ENV PATH="/usr/local/python/current/bin:/usr/local/ruby/current/bin:${PATH}"
#
# Updating a pin: change the version and digests in the PINS section below,
# taking the digests from the upstream release's published checksum file, and
# rebuild one image on each architecture. A wrong digest fails the build; it
# never installs.

set -euo pipefail

PREFIX="${TOOLCHAIN_PREFIX:-/usr/local}"

# ── PINS ────────────────────────────────────────────────────────────────────
# Each pin is an exact upstream release and the digest of the file fetched.

GIT_LFS_VERSION="3.8.1"

# python-build-standalone release tag; every Python pin below is from it.
PYTHON_BUILD_TAG="20261110"

# ruby-build release and the commit that tag names. ruby-build carries the
# digest of every Ruby source archive it can build.
RUBY_BUILD_TAG="v20261023"
RUBY_BUILD_COMMIT="b6a92c15f0df872047c74f7dfa0b92dfd4de8a92"

# Prints the SHA-256 for <tool> <architecture>, or nothing if there is no pin.
pin_sha256() {
    case "$1/$2" in
        git-lfs/amd64) echo "e72cf723a4a660438862282e8aecf3885fc8123e88bfcad534cf6b941a354b75" ;;
        git-lfs/arm64) echo "67895dd77b63329796bc5efdd47b57f218e1f7b98717ebaf936a8238dbcaec0f" ;;
        python-3.13/amd64) echo "50c774f6674740739f791c05a9177ed03e2fe02abebda9bca3512eb7309b37cc" ;;
        python-3.13/arm64) echo "d25a65036d5e149db902fa52ad65878d0c00e9301360ec197832f99063087e9e" ;;
    esac
}

# Prints the exact Python version pinned for a minor series, or nothing.
pin_python_version() {
    case "$1" in
        3.13) echo "3.13.18" ;;
    esac
}

PINNED_PYTHON_SERIES="3.13"

# ── Helpers ─────────────────────────────────────────────────────────────────

die() {
    echo "install-toolchain: $*" >&2
    exit 1
}

# Prints amd64 or arm64; anything else has no pinned artifact.
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) die "no pinned artifacts for architecture '$machine'" ;;
    esac
}

# fetch_verified <url> <sha256> <destination>
# The digest check is the only thing that makes a download trustworthy here,
# so a missing digest is refused rather than treated as "skip verification".
fetch_verified() {
    local url="$1" sha="$2" dest="$3"
    [ -n "$sha" ] || die "no pinned SHA-256 for $url"
    curl --fail --location --silent --show-error \
        --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
        --output "$dest" "$url" \
        || die "download failed: $url"
    local actual
    actual="$(sha256sum "$dest" | cut -d' ' -f1)"
    if [ "$actual" != "$sha" ]; then
        rm -f "$dest"
        die "SHA-256 mismatch for $url (expected $sha, got $actual)"
    fi
}

ensure_curl() {
    command -v curl >/dev/null 2>&1 && return 0
    command -v apt-get >/dev/null 2>&1 \
        || die "curl is required and this image has no apt-get to install it"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates
    rm -rf /var/lib/apt/lists/*
}

# Prints the account that should own the interpreter trees, or nothing.
resolve_owner() {
    local requested="$1" name
    if [ -n "$requested" ]; then
        id -u "$requested" >/dev/null 2>&1 || die "--user '$requested' does not exist in this image"
        echo "$requested"
        return 0
    fi
    name="$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)"
    echo "$name"
}

# give_to_owner <owner> <path>: only root can hand a tree to someone else.
give_to_owner() {
    local owner="$1" path="$2"
    [ -n "$owner" ] || return 0
    [ "$(id -u)" -eq 0 ] || return 0
    chown -R "$owner" "$path"
}

# link_bins <tree-bin-dir> <name>...: expose the named executables that exist.
link_bins() {
    local bindir="$1" name
    shift
    mkdir -p "$PREFIX/bin"
    for name in "$@"; do
        if [ -x "$bindir/$name" ]; then
            ln -sfn "$bindir/$name" "$PREFIX/bin/$name"
        fi
    done
}

# ── Git LFS ─────────────────────────────────────────────────────────────────

install_git_lfs() {
    local arch="$1" work="$2"
    local target="$PREFIX/bin/git-lfs"
    if [ -x "$target" ] && "$target" version 2>/dev/null | grep -q "^git-lfs/${GIT_LFS_VERSION} "; then
        echo "(*) Git LFS ${GIT_LFS_VERSION} already installed"
        return 0
    fi
    echo "(*) Installing Git LFS ${GIT_LFS_VERSION}..."
    local file="git-lfs-linux-${arch}-v${GIT_LFS_VERSION}.tar.gz"
    fetch_verified \
        "https://github.com/git-lfs/git-lfs/releases/download/v${GIT_LFS_VERSION}/${file}" \
        "$(pin_sha256 git-lfs "$arch")" "$work/$file"
    mkdir -p "$work/git-lfs" "$PREFIX/bin"
    tar -xzf "$work/$file" -C "$work/git-lfs"
    local binary
    binary="$(find "$work/git-lfs" -type f -name git-lfs | head -n 1)"
    [ -n "$binary" ] || die "no git-lfs binary inside $file"
    install -m 0755 "$binary" "$target"
    "$target" version | grep -q "^git-lfs/${GIT_LFS_VERSION} " \
        || die "installed git-lfs does not report version ${GIT_LFS_VERSION}"
}

# ── Python ──────────────────────────────────────────────────────────────────

install_python() {
    local series="$1" arch="$2" work="$3" owner="$4"
    local version triple
    version="$(pin_python_version "$series")"
    [ -n "$version" ] || die "no pinned Python for '$series' (pinned: ${PINNED_PYTHON_SERIES})"
    case "$arch" in
        amd64) triple="x86_64-unknown-linux-gnu" ;;
        arm64) triple="aarch64-unknown-linux-gnu" ;;
    esac
    local tree="$PREFIX/python/$version"
    if [ -x "$tree/bin/python3" ] && [ "$("$tree/bin/python3" --version 2>&1)" = "Python $version" ]; then
        echo "(*) Python ${version} already installed"
    else
        echo "(*) Installing Python ${version}..."
        local file="cpython-${version}+${PYTHON_BUILD_TAG}-${triple}-install_only.tar.gz"
        # '+' in the asset name is a literal plus; GitHub wants it percent-encoded.
        fetch_verified \
            "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD_TAG}/${file//+/%2B}" \
            "$(pin_sha256 "python-$series" "$arch")" "$work/$file"
        rm -rf "$tree"
        mkdir -p "$tree"
        # The archive's single top-level directory is `python/`.
        tar -xzf "$work/$file" -C "$tree" --strip-components=1
    fi
    ln -sfn "$version" "$PREFIX/python/current"
    link_bins "$PREFIX/python/current/bin" python3 python "python$series" pip pip3 "pip$series"
    [ "$("$PREFIX/bin/python3" --version 2>&1)" = "Python $version" ] \
        || die "$PREFIX/bin/python3 does not report Python $version"
    "$PREFIX/bin/python3" -c 'import ssl, sqlite3, venv, ensurepip' \
        || die "installed Python is missing a standard module"
    give_to_owner "$owner" "$PREFIX/python"
}

# ── Ruby ────────────────────────────────────────────────────────────────────

install_ruby() {
    local series="$1" work="$2" owner="$3"
    command -v apt-get >/dev/null 2>&1 \
        || die "--ruby builds from source and needs apt-get for its build dependencies"
    echo "(*) Installing Ruby ${series} build dependencies..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        autoconf build-essential ca-certificates git patch \
        libdb-dev libffi-dev libgdbm-dev libgmp-dev libncurses-dev \
        libreadline-dev libssl-dev libyaml-dev uuid-dev zlib1g-dev
    rm -rf /var/lib/apt/lists/*

    git clone --quiet --depth 1 --branch "$RUBY_BUILD_TAG" \
        https://github.com/rbenv/ruby-build.git "$work/ruby-build" \
        || die "could not clone ruby-build $RUBY_BUILD_TAG"
    local commit
    commit="$(git -C "$work/ruby-build" rev-parse HEAD)"
    [ "$commit" = "$RUBY_BUILD_COMMIT" ] \
        || die "ruby-build $RUBY_BUILD_TAG is commit $commit, expected $RUBY_BUILD_COMMIT"

    # The newest patch release of the series that the pinned ruby-build knows.
    local version
    version="$("$work/ruby-build/bin/ruby-build" --definitions \
        | grep -E "^${series//./\\.}\.[0-9]+$" | sort -V | tail -n 1)"
    [ -n "$version" ] || die "ruby-build $RUBY_BUILD_TAG has no definition for Ruby $series"

    local tree="$PREFIX/ruby/$version"
    if [ -x "$tree/bin/ruby" ] && "$tree/bin/ruby" --version 2>/dev/null | grep -q "^ruby $version"; then
        echo "(*) Ruby ${version} already installed"
    else
        echo "(*) Building Ruby ${version} (this takes several minutes)..."
        rm -rf "$tree"
        MAKE_OPTS="-j$(nproc)" RUBY_CONFIGURE_OPTS="--disable-install-doc" \
            "$work/ruby-build/bin/ruby-build" "$version" "$tree" \
            || die "ruby-build failed for Ruby $version"
    fi
    ln -sfn "$version" "$PREFIX/ruby/current"
    link_bins "$PREFIX/ruby/current/bin" ruby gem bundle bundler rake irb erb rdoc ri
    "$PREFIX/bin/ruby" --version | grep -q "^ruby $version" \
        || die "$PREFIX/bin/ruby does not report Ruby $version"
    "$PREFIX/bin/ruby" -e 'require "openssl"; require "yaml"; require "zlib"' \
        || die "installed Ruby is missing a standard extension"
    give_to_owner "$owner" "$PREFIX/ruby"
}

# ── Entry point ─────────────────────────────────────────────────────────────

main() {
    local python_series="" ruby_series="" with_git_lfs=true requested_user=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --python) [ "$#" -ge 2 ] || die "--python needs a version"; python_series="$2"; shift 2 ;;
            --ruby) [ "$#" -ge 2 ] || die "--ruby needs a version"; ruby_series="$2"; shift 2 ;;
            --user) [ "$#" -ge 2 ] || die "--user needs a name"; requested_user="$2"; shift 2 ;;
            --no-git-lfs) with_git_lfs=false; shift ;;
            -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) die "unknown argument '$1'" ;;
        esac
    done

    # Reject an unpinned request before any download or package install.
    if [ -n "$python_series" ] && [ -z "$(pin_python_version "$python_series")" ]; then
        die "no pinned Python for '$python_series' (pinned: ${PINNED_PYTHON_SERIES})"
    fi
    if [ -n "$ruby_series" ] && ! [[ "$ruby_series" =~ ^[0-9]+\.[0-9]+$ ]]; then
        die "--ruby takes a minor series such as 3.3, not '$ruby_series'"
    fi

    local arch owner work
    arch="$(detect_arch)"
    owner="$(resolve_owner "$requested_user")"
    ensure_curl
    work="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand now: $work is local to main
    trap "rm -rf '$work'" EXIT

    if $with_git_lfs; then
        install_git_lfs "$arch" "$work"
    fi
    if [ -n "$python_series" ]; then
        install_python "$python_series" "$arch" "$work" "$owner"
    fi
    if [ -n "$ruby_series" ]; then
        install_ruby "$ruby_series" "$work" "$owner"
    fi
    echo "(*) Toolchain install complete."
}

# Sourced by tests to exercise single functions; run directly everywhere else.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
