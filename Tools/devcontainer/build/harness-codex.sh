#!/bin/bash
# harness-codex.sh — install and configure Codex.
#
# Run by the neutral setup.sh beside it, at Docker build time (and on a live re-run).

set -euo pipefail

HARNESS_SELF="${BASH_SOURCE[0]:?harness-codex.sh must be run as a file (bash harness-codex.sh), not piped on stdin}"
BUILD_DIR="$(cd "$(dirname "$HARNESS_SELF")" && pwd)"

# shellcheck source=Tools/devcontainer/build/lib.sh
source "$BUILD_DIR/lib.sh"

# 1. Codex CLI, from the official STANDALONE installer.
#
# Deliberately not the npm channel (`npm i -g @openai/codex`). These images install node
# through a devcontainer feature that layers on *after* this build-time script, so an npm
# install would either fail here or have to be deferred to a lifecycle hook; and it would
# make Codex the one harness whose presence depends on a node toolchain that projects
# without one do not otherwise need. The standalone installer has neither problem and is
# the same shape as the other two harnesses' installs.
harness_install_via_curl codex https://chatgpt.com/codex/install.sh "Codex CLI"

# 2. Codex keybindings: Enter inserts a newline; Shift+Enter submits.
#
# Context-specific bindings keep Enter's ordinary confirm behavior in lists and approval
# prompts. Retain Ctrl+J as the terminal-portable newline fallback. Upsert the two keys
# rather than replacing config.toml: Codex keeps model, provider, MCP, and other personal
# settings in the same file, and this script is deliberately safe to re-run live.
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONFIG="$CODEX_DIR/config.toml"
harness_upsert_toml_key "$CODEX_CONFIG" "tui.keymap.editor" "insert_newline" '["enter", "ctrl-j"]'
harness_upsert_toml_key "$CODEX_CONFIG" "tui.keymap.composer" "submit" '["shift-enter"]'
echo "  Codex keybindings configured"

# 3. 'cx' — launch Codex with approvals and sandboxing bypassed.
#
# The flag's own help text says it is "intended solely for running in environments that
# are externally sandboxed", which is exactly what a devcontainer is. This is the direct
# counterpart of `cc`; see the README's "Launch shortcuts and permission behavior".
#
# Codex ships a second, narrower bypass flag (--dangerously-bypass-hook-trust) which this
# alias deliberately does NOT pass: it governs whether unvetted hooks run, which is a
# different question from whether the agent may act without asking, and the container
# sandbox is not an argument for it.
harness_alias cx 'alias cx="codex --dangerously-bypass-approvals-and-sandbox"'
echo "  'cx' alias configured"

# 4. Authentication is deliberately not attempted here.
#
# `~/.codex/auth.json` is per-user state that an image cannot bake — the same is true of
# Claude's and omp's credentials. "Installed" and "signed in" are separate claims, and
# everything in this kit only ever makes the first: run `codex login` once per container.

harness_record codex
