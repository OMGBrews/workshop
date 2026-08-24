#!/bin/bash
# Validate that devcontainer setup completed correctly.
# Called by postStartCommand. Fails loudly if any check fails — no silent repair.
#
# ── Why the harness checks are gated on a manifest ──────────────────────────────────
# This script runs LIVE off the mounted devtools clone at every container start, so an
# edit here reaches every consumer the moment its pointer moves. Installs, by contrast,
# land at image BUILD. Those two clocks are what make the obvious implementation wrong:
# a plain `command -v omp` check would go red in every consumer at its next container
# start — the whole fleet — for a rebuild nobody has done yet, and `postStartCommand`
# failure is how most consumers wire this.
#
# So the assertion is not "the fleet's harnesses are installed" but "this image has what
# it says it has": build/setup.sh writes ~/.devcontainer-harnesses naming each harness it
# configured, and only those are checked. An image with no manifest predates the
# multi-harness kit, and its correct expectation is exactly the Claude-only set this
# script has always asserted.
#
# The manifest is baked, never inferred. Asking the container what it happens to contain
# would make this check pass on any state at all, including the state where a build
# silently installed nothing.

set -euo pipefail

VALIDATE_SELF="${BASH_SOURCE[0]:?validate_setup.sh must be run as a file}"
KIT_DIR="$(cd "$(dirname "$VALIDATE_SELF")" && pwd)"

# harness_locate lives in the build kit, so "is this harness installed?" is answered the
# same way here as it is at install time. A second copy of that PATH-plus-known-dirs
# search would be free to drift, and the two disagreeing means either a false FAIL at
# startup or a build that reported an install it did not make.
# shellcheck source=Tools/devcontainer/build/lib.sh
source "$KIT_DIR/build/lib.sh"

ERRORS=0

check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  OK: $description"
    else
        echo "  FAIL: $description"
        ERRORS=$((ERRORS + 1))
    fi
}

# An alias must be in BOTH rc files, not just .bashrc.
#
# setup.sh has always written to .bashrc and .zshrc — the base image's login shell is zsh
# while every script and a plain `docker exec` get bash — but this script checked only
# .bashrc, so a half-written alias validated clean. That is the omission shape: the check
# passed in exactly the state it existed to catch, on the shell the human actually uses.
check_alias_both_rcfiles() {
    local name="$1" rcfile
    while IFS= read -r rcfile; do
        [ -f "$rcfile" ] || return 1
        grep -qF "alias $name=" "$rcfile" || return 1
    done < <(harness_rcfiles)
}

echo "=== Validating devcontainer setup ==="

# --- Neutral: true of every image this kit has ever built --------------------------
check "Git LFS clean filter" git config --global filter.lfs.clean
check "Git LFS smudge filter" git config --global filter.lfs.smudge
check "Git LFS process filter" git config --global filter.lfs.process
# The Claude status line shells out to jq on every turn; a missing jq would leave it
# silently blank rather than erroring visibly.
check "jq present (status line depends on it)" command -v jq

# --- Identity, on new-shape images only ---------------------------------------------
# A container with no identity cannot commit, and the way that is normally discovered is
# the first refused commit, hours in, with a message that names none of this.
#
# Gated on ~/.config/git/config the same way the harness checks are gated on the
# manifest, and for the same two-clocks reason: this script runs live off the mounted
# clone at every container start, while the arrangement that makes identity arrive is
# written at image BUILD. That file's presence is the baked marker of a build that left
# ~/.gitconfig free for the host copy. An older image, whose build occupied ~/.gitconfig,
# cannot satisfy this check by any action taken inside it — asserting it there would go
# red across the fleet for a rebuild nobody has done.
#
# --global scope, not unscoped: a repo-local identity — the hand-configured workaround
# people reach for when a container comes up anonymous — would satisfy an unscoped read
# in exactly the no-inheritance state this exists to catch.
if [ -f "$HOME/.config/git/config" ]; then
    identity_name="$(git config --global --get user.name 2>/dev/null || true)"
    identity_email="$(git config --global --get user.email 2>/dev/null || true)"
    if [ -n "$identity_name" ] && [ -n "$identity_email" ]; then
        echo "  OK: git identity present in global scope ($identity_email)"
    else
        echo "  FAIL: no git user.name/user.email in global scope — this container cannot commit"
        echo "        A container gets its identity from the machine it runs on: the Dev"
        echo "        Containers extension copies the host's ~/.gitconfig in when you attach."
        echo "        This kit keeps its own settings in ~/.config/git/config precisely so"
        echo "        ~/.gitconfig is free for that copy to land in. An empty identity here"
        echo "        means the copy did not happen — attached by a client that does not do"
        echo "        it, dev.containers.copyGitConfig turned off, or a host with no identity"
        echo "        of its own. Set it on the host and reattach, or set it here directly:"
        echo "          git config --global user.name  \"Your Name\""
        echo "          git config --global user.email \"you@example.com\""
        ERRORS=$((ERRORS + 1))
    fi
fi

# --- Per harness, from the baked manifest ------------------------------------------
validate_claude() {
    check "Claude settings exist" test -f "$HOME/.claude/settings.json"
    check "Claude settings has permissions" grep -q '"allow"' "$HOME/.claude/settings.json"
    check "Claude status line script installed" test -x "$HOME/.claude/statusline.sh"
    check "Claude status line wired into settings" grep -q '"statusLine"' "$HOME/.claude/settings.json"
    check "Claude Enter inserts newline" jq -e '.bindings[] | select(.context == "Chat") | .bindings.enter == "chat:newline"' "$HOME/.claude/keybindings.json"
    check "Claude Shift+Enter submits" jq -e '.bindings[] | select(.context == "Chat") | .bindings["shift+enter"] == "chat:submit"' "$HOME/.claude/keybindings.json"
    check "Claude Code CLI installed" harness_locate claude
    check "'cc' alias in bashrc and zshrc" check_alias_both_rcfiles cc
}

validate_omp() {
    check "Oh My Pi (omp) installed" harness_locate omp
    check "Oh My Pi Enter inserts newline" grep -qxF 'tui.input.newLine: [Enter, Ctrl+J]' "${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/keybindings.yml"
    check "Oh My Pi Shift+Enter submits" grep -qxF 'tui.input.submit: [Shift+Enter]' "${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/keybindings.yml"
    # No alias check: omp deliberately has none — its sessions already default to the
    # always-approve mode `cc` and `cx` exist to reach. See build/harness-omp.sh.
}

validate_codex() {
    check "Codex CLI installed" harness_locate codex
    check "Codex Enter inserts newline" awk '
        /^\[tui\.keymap\.editor\]$/ { in_editor = 1; next }
        /^\[/ { in_editor = 0 }
        in_editor && /^insert_newline[[:space:]]*=[[:space:]]*\[[^]]*"enter"/ { found = 1 }
        END { exit !found }
    ' "${CODEX_HOME:-$HOME/.codex}/config.toml"
    check "Codex Shift+Enter submits" awk '
        /^\[tui\.keymap\.composer\]$/ { in_composer = 1; next }
        /^\[/ { in_composer = 0 }
        in_composer && /^submit[[:space:]]*=[[:space:]]*\[[^]]*"shift-enter"/ { found = 1 }
        END { exit !found }
    ' "${CODEX_HOME:-$HOME/.codex}/config.toml"
    check "'cx' alias in bashrc and zshrc" check_alias_both_rcfiles cx
}

if [ -r "$HARNESS_MANIFEST" ]; then
    while IFS= read -r harness; do
        [ -n "$harness" ] || continue
        if declare -F "validate_$harness" >/dev/null; then
            "validate_$harness"
        else
            # The image says it installed something this script has no checks for. That is
            # a gap in the validator, not a broken container, so it is reported as a
            # finding rather than passed over — a silently unvalidated harness is how the
            # manifest stops meaning anything.
            echo "  FAIL: image claims harness '$harness' but this validator has no checks for it"
            ERRORS=$((ERRORS + 1))
        fi
    done < "$HARNESS_MANIFEST"
else
    # Pre-multi-harness image. Claude Code is what it installed, so Claude Code is what
    # is asserted — the same set this script checked before the kit gained a manifest.
    echo "  (no harness manifest — pre-multi-harness image; checking Claude Code only)"
    validate_claude
fi

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "ERROR: $ERRORS setup check(s) failed."
    echo "The devcontainer image may need to be rebuilt."
    echo "Run: Dev Containers: Rebuild Container"
    exit 1
fi

echo "=== All setup checks passed ==="
