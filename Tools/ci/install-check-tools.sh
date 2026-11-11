#!/usr/bin/env bash
# Install the two programs `make check` needs beyond a stock CI runner:
# ShellCheck and zsh. Both come from pinned GitHub release archives verified
# against SHA-256 digests written here.
#
# Usage (CI runs it with sudo; the default prefix is /usr/local):
#   sudo bash Tools/ci/install-check-tools.sh [prefix]
#
# Why not `apt-get install shellcheck zsh`. The workflow did exactly that, and
# on 2026-11-11 every job failed in that step because the runner could not
# resolve archive.ubuntu.com. A required status check that depends on the
# distribution's package archive is unavailable whenever the archive is, and
# nothing can land meanwhile. It also linted with whichever ShellCheck the
# runner image's release carried, so a runner image upgrade could change the
# verdict on unchanged code. Pinned archives remove both: the only host
# contacted is github.com, which the job already needs to check out the code.
#
# zsh is the statically linked build from romkatv/zsh-bin. It expects its
# function files under <prefix>/share/zsh, so install it to a real prefix
# rather than running it from the extracted archive.
#
# Updating a pin: change the version and both digests, taking the digests
# from the upstream release, and let the pull request's own run prove it.
set -euo pipefail

PREFIX="${1:-/usr/local}"

SHELLCHECK_VERSION="0.11.0"
ZSH_BIN_RELEASE="v6.1.1"
ZSH_VERSION_PINNED="5.8"

case "$(uname -m)" in
    x86_64|amd64)
        arch=x86_64
        shellcheck_sha="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
        zsh_sha="6df668fb6e9a12874e0d80518d582f2e99e512d4a4532fa73d938360aaddc838"
        ;;
    aarch64|arm64)
        arch=aarch64
        shellcheck_sha="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"
        zsh_sha="5caca77bcdaa218ec12e79f2e65c53c39058e0ed4f4f299991d18a800ca7c06d"
        ;;
    *)
        echo "install-check-tools: no pinned archives for $(uname -m)" >&2
        exit 1
        ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# fetch <url> <sha256> <destination>: a download counts only if its digest matches.
fetch() {
    curl --fail --location --silent --show-error \
        --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
        --output "$3" "$1"
    echo "$2  $3" | sha256sum --check --quiet -
}

mkdir -p "$PREFIX/bin"

fetch "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${arch}.tar.xz" \
    "$shellcheck_sha" "$work/shellcheck.tar.xz"
tar -xJf "$work/shellcheck.tar.xz" -C "$work"
install -m 0755 "$work/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$PREFIX/bin/shellcheck"

fetch "https://github.com/romkatv/zsh-bin/releases/download/${ZSH_BIN_RELEASE}/zsh-${ZSH_VERSION_PINNED}-linux-${arch}.tar.gz" \
    "$zsh_sha" "$work/zsh.tar.gz"
tar -xzf "$work/zsh.tar.gz" -C "$PREFIX" --no-same-owner

# Report what a later step will actually resolve, and fail if it is not ours.
"$PREFIX/bin/shellcheck" --version | grep -qx "version: ${SHELLCHECK_VERSION}"
"$PREFIX/bin/zsh" --version | grep -q "^zsh ${ZSH_VERSION_PINNED} "
echo "installed shellcheck ${SHELLCHECK_VERSION} and zsh ${ZSH_VERSION_PINNED} under ${PREFIX}"
