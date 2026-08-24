#!/bin/bash
# harness-omp.sh — install Oh My Pi (`omp`).
#
# Run by the neutral setup.sh beside it, at Docker build time (and on a live re-run).
#
# The shortest of the three harness files, and deliberately so: omp needs no settings
# file, no status line, and — see below — no alias.

set -euo pipefail

HARNESS_SELF="${BASH_SOURCE[0]:?harness-omp.sh must be run as a file (bash harness-omp.sh), not piped on stdin}"
BUILD_DIR="$(cd "$(dirname "$HARNESS_SELF")" && pwd)"

# shellcheck source=Tools/devcontainer/build/lib.sh
source "$BUILD_DIR/lib.sh"

# 1. Oh My Pi CLI, from its official standalone installer.
harness_install_via_curl omp https://omp.sh/install "Oh My Pi (omp)"

# 2. OMP keybindings: Enter inserts a newline; Shift+Enter submits.
#
# The file is a flat YAML action map, separate from config.yml. Ctrl+J remains the
# portable newline fallback. Do not remap app.message.followUp: its current Ctrl+Enter
# default does not collide with Shift+Enter and remains useful while a task is running.
OMP_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
OMP_KEYBINDINGS="$OMP_AGENT_DIR/keybindings.yml"
harness_upsert_flat_yaml_key "$OMP_KEYBINDINGS" "tui.input.newLine" '[Enter, Ctrl+J]'
harness_upsert_flat_yaml_key "$OMP_KEYBINDINGS" "tui.input.submit" '[Shift+Enter]'
echo "  Oh My Pi keybindings configured"

# 3. No alias, on purpose.
#
# `cc` and `cx` exist because Claude Code and Codex both prompt for approval by default,
# so a shortcut is needed to launch them in the always-approve mode a sandboxed container
# makes safe. omp already starts that way: its `tools.approvalMode` setting defaults to
# `yolo` (confirmed with `omp config get tools.approvalMode`, whose schema reads
# `always-ask|write|yolo`), so a bare `omp` is the equivalent launch, and an alias would
# be an alias for the default.
#
# This asymmetry is documented rather than smoothed over, because it is the kind of thing
# that reads as an oversight later: the README's "Launch shortcuts and permission
# behavior" section states that the supported set is `cc`, `cx`, and bare `omp`, and why
# the third has no letter. If omp ever changes its default, the fix is an `omp` alias
# passing `--approval-mode=yolo` here — not a change to the other two.

harness_record omp
