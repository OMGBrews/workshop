#!/usr/bin/env bash
# SessionStart hook: the Claude Code bridge to the harness-neutral session
# bootstrap at scripts/agent/session-start.sh.
#
# THIS FILE HOLDS NO BOOTSTRAP LOGIC. Everything that fetches, fast-forwards,
# initializes submodules, or reports pointer lag lives in the neutral script,
# which any harness — and any human, and CI — runs as a plain command:
#   bash scripts/agent/session-start.sh
# All this wrapper adds is the vendor-specific envelope Claude Code needs and
# no other harness understands. Splitting them is what keeps the bootstrap a
# surface every harness reaches rather than a Claude-only feature
# (<shared-tools mount>/docs/harness-agnostic-repos.md, surface 3).
#
# Canonical copy: <shared-tools mount>/docs/templates/cloud-sessions/session-start.sh —
# each project carries its own copy at .claude/hooks/session-start.sh, because
# a hook whose job includes initializing the shared-tools tree cannot live inside
# it.
# The copies are promised byte-for-byte identical; the drift guard lives in the
# neutral script (which always runs) and checks BOTH files every session.
#
# What the envelope carries, and why it cannot live in the neutral script:
#   - the JSON object itself: Claude Code parses a SessionStart hook's stdout
#     as JSON on exit 0. Plain lines are still shown as context, so a harness
#     running the neutral script directly loses nothing but the two fields
#     below.
#   - additionalContext: the neutral script's report, delivered to the session
#     exactly as its plain-text form would be.
#   - reloadSkills: a request to rebuild the skill registry AFTER this hook
#     completes and BEFORE the first user message. The registry is built once
#     from `.claude/skills/*`, and a per-skill symlink that dangled when it was
#     built stays unregistered for the whole session: populating the submodule
#     afterwards restores the files, never the slash commands
#     (observed 2026-07-29 — `/ship` answered `Unknown skill: ship` with its
#     SKILL.md readable on disk). Asking for the reload is the
#     documented remedy, and it is requested exactly when the neutral script
#     reports having initialized or re-synced a submodule — which it signals by
#     writing the marker file named in AGENT_BOOTSTRAP_RELOAD_MARKER. A session
#     that changed nothing asks for nothing.
#   - project-path translation: CLAUDE_PROJECT_DIR -> AGENT_PROJECT_DIR.
#     Session detection belongs to the kit's shared harness-signals.sh, sourced
#     by the neutral bootstrap. This wrapper does not interpret location signals.
#
# Silence is still silence: with no report and no reload to request, nothing is
# printed at all. And if stdout ever fails to parse as JSON, Claude Code falls
# back to treating it as plain context text, so a malformed emission degrades
# to a visible report rather than a silent one.
#
# Wired in .claude/settings.json (SessionStart; see settings-hooks.json in the
# template directory).
set -u
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" || exit 0

NEUTRAL="scripts/agent/session-start.sh"

# JSON-escape one string for use as a JSON string body (no surrounding quotes).
# Bash parameter expansion, so no jq/python dependency at session start.
# Control characters other than tab and newline are stripped by the caller
# before this runs — they are illegal raw in JSON and carry no information here
# (git writes no color to a non-tty).
_json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# <report-text> <reload:1|empty> — the whole vendor envelope, or byte-nothing.
_emit() {
  local report="$1" reload="$2" json=""
  [ -z "$report" ] && [ -z "$reload" ] && return 0   # nothing to say
  json='{"hookSpecificOutput":{"hookEventName":"SessionStart"'
  [ -n "$report" ] && json="$json,\"additionalContext\":\"$(_json_string "$report")\""
  [ -n "$reload" ] && json="$json,\"reloadSkills\":true"
  printf '%s\n' "$json}}"
}

# The bootstrap missing is the one failure this wrapper can detect and no other
# check would: the hook fires, nothing bootstraps, and a stale checkout with
# uninitialized submodules looks exactly like a healthy one. Say so loudly
# rather than exiting quietly — and name the redeploy, because the usual cause
# is a shared-tools bump that landed the split without the matching redeploy.
if [ ! -f "$NEUTRAL" ]; then
  _emit "[session-start] MISSING: $NEUTRAL is absent, so NO session bootstrap ran — no fetch, no submodule init, no staleness or pointer-lag report. This checkout may be stale and its submodules uninitialized, with nothing else to say so.
[session-start]   Deploy it from the kit: mkdir -p scripts/agent && cp <shared-tools mount>/docs/templates/cloud-sessions/agent-session-start.sh $NEUTRAL && chmod +x $NEUTRAL
[session-start]   (If the shared-tools tree is itself uninitialized, run: git submodule update --init <mount> — that is the chicken-and-egg this bootstrap exists to solve.)" ""
  exit 0
fi

# Capture the neutral script's report, and give it a marker file to signal that
# it changed a submodule checkout. If mktemp fails we run it with stdout
# passed straight through: the body then prints plain text, which Claude Code
# still shows as context. That degradation costs the reload request, not the
# report.
_report_capture=""; _reload_marker=""
if ! { _report_capture="$(mktemp 2>/dev/null)" && _reload_marker="$(mktemp 2>/dev/null)"; }; then
  rm -f "$_report_capture" "$_reload_marker"
  AGENT_PROJECT_DIR="$PWD" \
    bash "$NEUTRAL"
  exit 0
fi
trap 'rm -f "$_report_capture" "$_reload_marker"' EXIT

AGENT_PROJECT_DIR="$PWD" \
AGENT_BOOTSTRAP_RELOAD_MARKER="$_reload_marker" \
  bash "$NEUTRAL" > "$_report_capture"

report="$(LC_ALL=C tr -d '\000-\010\013-\037' < "$_report_capture")"
reload=""; [ -s "$_reload_marker" ] && reload=1
_emit "$report" "$reload"
exit 0
