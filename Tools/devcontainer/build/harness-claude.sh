#!/bin/bash
# harness-claude.sh — install and configure Claude Code.
#
# Run by the neutral setup.sh beside it, at Docker build time (and on a live re-run).
# Everything Claude-specific that used to sit in the single setup.sh lives here:
# the CLI, ~/.claude/settings.json, keybindings, the status line, and the `cc` alias.

set -euo pipefail

HARNESS_SELF="${BASH_SOURCE[0]:?harness-claude.sh must be run as a file (bash harness-claude.sh), not piped on stdin: the statusline lookup needs its own path}"
BUILD_DIR="$(cd "$(dirname "$HARNESS_SELF")" && pwd)"

# shellcheck source=Tools/devcontainer/build/lib.sh
source "$BUILD_DIR/lib.sh"

# 1. Claude Code CLI
harness_install_via_curl claude https://claude.ai/install.sh "Claude Code CLI"

# 2. Claude Code settings (YOLO mode for sandbox) + status line
CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"
SETTINGS="$CLAUDE_DIR/settings.json"

# CLAUDE_CODE_SCROLL_SPEED pairs with terminal.integrated.mouseWheelScrollSensitivity=9
# in the HOST VS Code user settings: the MX Master's high-resolution wheel emits deltas
# too small for the terminal's mouse-reporting conversion, so sensitivity gates whether
# wheel events reach Claude Code at all, and this sets lines-per-event once they do.
# Change both together or scrolling regresses to dead clicks / 3-line jumps.
#
# agentPushNotifEnabled lets the agent send proactive notifications to the Claude
# mobile app; it defaults to false, so a rebuild silently drops it. Seeding it here
# is what makes it survive one. It is not a way to get pinged constantly: the tool
# skips the send with disabledReason "user_present" whenever you are actually at the
# terminal, so it fires only when a long unattended run finishes and you have walked
# away. Note this key is set on EVERY run, so toggling it off via /config is undone
# the next time this script executes — remove it here to turn it off for good.
DESIRED_SETTINGS='{
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "Glob(*)",
      "Grep(*)",
      "WebFetch(*)",
      "WebSearch(*)"
    ],
    "deny": []
  },
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "refreshInterval": 15
  },
  "env": {
    "CLAUDE_CODE_SCROLL_SPEED": "1"
  },
  "agentPushNotifEnabled": true
}'

# Merge into any existing settings rather than overwriting. Two reasons: a
# rebuild is not the only way to pick this up (the script must be safe to re-run
# inside a live container), and a human's local tweaks — model, theme, tui — must
# survive that re-run. `. * $d` deep-merges with our keys winning. jq comes from
# install-packages.sh, which every Dockerfile runs before this script.
if [ -s "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --argjson d "$DESIRED_SETTINGS" '. * $d' "$SETTINGS" > "$tmp" && mv -f "$tmp" "$SETTINGS"
    echo "  Claude settings merged (existing keys preserved)"
else
    printf '%s\n' "$DESIRED_SETTINGS" > "$SETTINGS"
    echo "  Claude settings configured"
fi

# 3. Claude Code keybindings: Enter inserts a newline; Shift+Enter submits.
#
# Claude Code 2.1.18+ uses the context/action schema below. The old flat array this kit
# installed (`command: newline`) predates that schema, so a valid legacy array is
# intentionally replaced. A current-format object is merged instead: unrelated contexts
# and Chat bindings remain the user's, while these two fleet defaults stay durable.
KEYBINDINGS="$CLAUDE_DIR/keybindings.json"
# shellcheck disable=SC2016 # $schema/$docs are literal JSON property names.
DESIRED_KEYBINDINGS='{
  "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
  "$docs": "https://code.claude.com/docs/en/keybindings",
  "bindings": [
    {
      "context": "Chat",
      "bindings": {
        "enter": "chat:newline",
        "shift+enter": "chat:submit"
      }
    }
  ]
}'

if [ -s "$KEYBINDINGS" ] \
   && jq -e 'type == "object" and (.bindings | type == "array")' "$KEYBINDINGS" >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq --argjson desired "$DESIRED_KEYBINDINGS" '
      .["$schema"] //= $desired["$schema"]
      | .["$docs"] //= $desired["$docs"]
      | .bindings = (
          [(.bindings[] | select(.context != "Chat"))]
          + [{
              "context": "Chat",
              "bindings": (
                reduce (.bindings[] | select(.context == "Chat") | (.bindings // {})) as $bindings
                  ({}; . * $bindings)
                | . * $desired.bindings[0].bindings
              )
            }]
        )
    ' "$KEYBINDINGS" > "$tmp" && mv -f "$tmp" "$KEYBINDINGS"
    echo "  Claude keybindings merged (existing bindings preserved)"
else
    printf '%s\n' "$DESIRED_KEYBINDINGS" > "$KEYBINDINGS"
    echo "  Claude keybindings configured"
fi

# 4. Claude Code status line.
#
# Installed by copying statusline.sh from this directory, which is the source of truth.
# It used to be a ~320-line heredoc inside setup.sh, which put two-thirds of that file
# inside one quoted string: invisible to shellcheck, miserable to diff, and one stray
# quote away from breaking the whole build.
#
# The sibling lookup is now structurally safe in a way it was not before the build/
# restructure. Under the old two-file COPY contract, each consuming Dockerfile had to
# land setup.sh and statusline.sh in the same directory under exactly those names, and
# hq's tests/verify-statusline-copy-contract.sh existed because 25 hand-edited
# Dockerfiles could each get that wrong. Consumers now COPY this whole directory, so the
# sibling arrives with the file that looks for it — the contract is a property of the
# kit rather than a rule every consumer must remember. The gate still checks it, because
# a Dockerfile can still COPY the wrong thing.
#
# A missing source is fatal here, never a skipped install. A build that shipped a
# container with no status line while reporting success is the decorative-success
# case docs/signal-hygiene.md exists to prevent.
#
# It shows what a shell prompt cannot: context-window fill, 5h/7d rate limits, and
# session cost. Deliberately omits user and cwd — both are fixed in a devcontainer,
# so they'd spend width restating what you already know.
STATUSLINE_SRC="$BUILD_DIR/statusline.sh"
[ -r "$STATUSLINE_SRC" ] || {
    echo "ERROR: statusline.sh not found beside harness-claude.sh (looked for $STATUSLINE_SRC)." >&2
    echo "       Every Dockerfile must COPY the whole devtools/Tools/devcontainer/build/" >&2
    echo "       directory, not individual files out of it." >&2
    exit 1
}
# Readable is not the property we need — it is merely the cheapest one to test. A
# zero-byte or truncated source passes `-r`, copies fine, and yields an installed,
# executable, entirely silent status line that validate_setup.sh's `test -x` also calls
# OK. So assert positive properties of the artifact: non-empty, a bash shebang, and
# syntactically valid.
IFS= read -r statusline_shebang < "$STATUSLINE_SRC" || statusline_shebang=""
case $statusline_shebang in
    '#!'*bash*) ;;
    *) echo "ERROR: $STATUSLINE_SRC is not a bash script (first line: ${statusline_shebang:-<empty>})." >&2
       echo "       Refusing to install it as the status line." >&2
       exit 1 ;;
esac
bash -n "$STATUSLINE_SRC" || {
    echo "ERROR: $STATUSLINE_SRC has a syntax error (above). Refusing to install it." >&2
    exit 1
}
# Copy via a temp + atomic mv, never straight onto the destination. This script is also
# re-run inside live containers, where the destination is a file a running claude executes
# on every prompt — an in-place rewrite is observable as a blank or half-drawn status line.
# The installed script uses the same temp-then-mv pattern on its own git cache, for the
# same reason. chmod before the mv so the destination is never briefly non-executable.
statusline_tmp="$CLAUDE_DIR/.statusline.sh.$$"
cp "$STATUSLINE_SRC" "$statusline_tmp"
chmod +x "$statusline_tmp"
mv -f "$statusline_tmp" "$CLAUDE_DIR/statusline.sh"
echo "  Claude status line installed"

# 5. 'cc' — launch Claude Code with permission prompts skipped.
#
# Safe here and nowhere else: the container is the sandbox. See the README's
# "Launch shortcuts and permission behavior" section for the contract this shares
# with `cx`, and for why omp has no equivalent.
harness_alias cc 'alias cc="claude --dangerously-skip-permissions"'
echo "  'cc' alias configured"

harness_record claude
