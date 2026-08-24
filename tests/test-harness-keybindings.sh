#!/usr/bin/env bash
# Regression tests for the three devcontainer harness keybinding installers.
#
# The shared contract is Enter -> newline and Shift+Enter -> submit. Each fixture also
# carries unrelated user configuration; retaining it proves a live setup re-run does not
# purchase durability by erasing personal settings. Stub binaries keep this test local
# and make a missing-install guard fail instead of reaching the network.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$WORKSHOP_ROOT/Tools/devcontainer/build"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

for binary in claude codex omp; do
  printf '#!/bin/sh\nexit 0\n' > "$WORK/$binary"
  chmod +x "$WORK/$binary"
done

SCRATCH_HOME="$WORK/home"
mkdir -p "$SCRATCH_HOME/.claude" "$SCRATCH_HOME/.codex" "$SCRATCH_HOME/.omp/agent"
printf '\n' > "$SCRATCH_HOME/.bashrc"
printf '\n' > "$SCRATCH_HOME/.zshrc"

cat > "$SCRATCH_HOME/.claude/keybindings.json" <<'EOF'
{
  "custom": true,
  "bindings": [
    {"context": "Global", "bindings": {"ctrl+r": "app:redraw"}},
    {"context": "Chat", "bindings": {"ctrl+e": "chat:externalEditor", "enter": "chat:submit"}}
  ]
}
EOF

cat > "$SCRATCH_HOME/.codex/config.toml" <<'EOF'
model = "keep-me"

[tui.keymap.editor]
move_left = ["ctrl-b"]
insert_newline = ["ctrl-j"]

[mcp_servers.keep-me]
command = "true"
EOF

cat > "$SCRATCH_HOME/.omp/agent/keybindings.yml" <<'EOF'
app.model.cycleForward: Ctrl+P
tui.input.newLine:
  - Shift+Enter
  - Ctrl+J
EOF

run_harness() {
  env -i \
    HOME="$SCRATCH_HOME" \
    PATH="$WORK:/usr/bin:/bin" \
    HARNESS_MANIFEST="$WORK/manifest" \
    bash "$BUILD_DIR/harness-$1.sh" >/dev/null
}

run_harness claude
run_harness codex
run_harness omp

jq -e '
  .custom == true
  and any(.bindings[]; .context == "Global" and .bindings["ctrl+r"] == "app:redraw")
  and any(.bindings[]; .context == "Chat"
    and .bindings["ctrl+e"] == "chat:externalEditor"
    and .bindings.enter == "chat:newline"
    and .bindings["shift+enter"] == "chat:submit")
' "$SCRATCH_HOME/.claude/keybindings.json" >/dev/null \
  || fail "Claude keybindings were not swapped while preserving existing bindings"

grep -q '^model = "keep-me"$' "$SCRATCH_HOME/.codex/config.toml" \
  || fail "Codex model setting was lost"
grep -q '^move_left = \["ctrl-b"\]$' "$SCRATCH_HOME/.codex/config.toml" \
  || fail "Codex editor binding was lost"
grep -q '^\[mcp_servers.keep-me\]$' "$SCRATCH_HOME/.codex/config.toml" \
  || fail "Codex MCP table was lost"
awk '
  /^\[tui\.keymap\.editor\]$/ { editor = 1; next }
  /^\[/ { editor = 0 }
  editor && /^insert_newline = \["enter", "ctrl-j"\]$/ { newline = 1 }
  /^\[tui\.keymap\.composer\]$/ { composer = 1; next }
  /^\[/ { composer = 0 }
  composer && /^submit = \["shift-enter"\]$/ { submit = 1 }
  END { exit !(newline && submit) }
' "$SCRATCH_HOME/.codex/config.toml" \
  || fail "Codex keybindings were not installed in their scoped tables"

grep -q '^app\.model\.cycleForward: Ctrl+P$' "$SCRATCH_HOME/.omp/agent/keybindings.yml" \
  || fail "OMP custom binding was lost"
grep -q '^tui\.input\.newLine: \[Enter, Ctrl+J\]$' "$SCRATCH_HOME/.omp/agent/keybindings.yml" \
  || fail "OMP Enter newline binding was not installed"
grep -q '^tui\.input\.submit: \[Shift+Enter\]$' "$SCRATCH_HOME/.omp/agent/keybindings.yml" \
  || fail "OMP Shift+Enter submit binding was not installed"
if grep -q '^[[:space:]]*- Shift+Enter$' "$SCRATCH_HOME/.omp/agent/keybindings.yml"; then
  fail "OMP block-style old value was left behind"
fi

# Repeat all three installers. Duplicate tables/keys are the dangerous idempotence
# failure here: they can look right to grep while making the actual config ambiguous or
# invalid to the harness parser.
run_harness claude
run_harness codex
run_harness omp

[ "$(grep -c '^\[tui\.keymap\.editor\]$' "$SCRATCH_HOME/.codex/config.toml")" -eq 1 ] \
  || fail "Codex editor table duplicated on re-run"
[ "$(grep -c '^\[tui\.keymap\.composer\]$' "$SCRATCH_HOME/.codex/config.toml")" -eq 1 ] \
  || fail "Codex composer table duplicated on re-run"
[ "$(grep -c '^tui\.input\.newLine:' "$SCRATCH_HOME/.omp/agent/keybindings.yml")" -eq 1 ] \
  || fail "OMP newline key duplicated on re-run"
[ "$(grep -c '^tui\.input\.submit:' "$SCRATCH_HOME/.omp/agent/keybindings.yml")" -eq 1 ] \
  || fail "OMP submit key duplicated on re-run"

echo "PASS: harness keybindings"
