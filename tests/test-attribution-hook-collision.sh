#!/usr/bin/env bash
# Adoption must preserve an active foreign commit-msg hook and explain why
# Workshop's commit hook was not enabled, through both public entry points.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset CLAUDE_CODE_REMOTE AGENT_SESSION_ENVIRONMENT AGENT_SESSION_REMOTE AGENT_SESSION_EPHEMERAL AGENT_SESSION_SIGNAL || true
fail() { echo "FAIL: $1" >&2; exit 1; }

fixture() {
  local repo=$1
  git init --quiet "$repo"
  mkdir -p "$repo/workshop/Tools/hooks" "$repo/.agents" \
    "$repo/workshop/.agents/skills/demo" "$repo/scripts/lib" \
    "$repo/workshop/docs/templates/cloud-sessions"
  printf '# Demo\n' > "$repo/workshop/.agents/skills/demo/SKILL.md"
  cp "$ROOT/Tools/configure-workshop-hooks.sh" "$repo/workshop/Tools/"
  cp "$ROOT/Tools/sync-skill-symlinks.sh" "$repo/workshop/Tools/"
  printf '#!/bin/sh\nexit 0\n' > "$repo/workshop/Tools/check-skill-roster-freshness.sh"
  printf '#!/bin/sh\n# Workshop commit-msg hook\nexit 0\n' > "$repo/workshop/Tools/hooks/commit-msg"
  chmod +x "$repo/workshop/Tools/hooks/commit-msg"
  cp "$ROOT/docs/templates/cloud-sessions/agent-session-start.sh" \
    "$repo/workshop/docs/templates/cloud-sessions/"
  cp "$ROOT/docs/templates/cloud-sessions/harness-signals.sh" "$repo/scripts/lib/"
}

adopt() {
  case $1 in
    sync) bash "$2/workshop/Tools/sync-skill-symlinks.sh" "$2" ;;
    session) AGENT_PROJECT_DIR="$2" bash "$2/workshop/docs/templates/cloud-sessions/agent-session-start.sh" ;;
  esac
}

for entry in sync session; do
  for location in default custom destination; do
    repo="$WORK/$entry-$location"
    fixture "$repo"
    case $location in
      default) foreign="$repo/.git/hooks/commit-msg"; expected="" ;;
      custom)
        mkdir -p "$repo/custom-hooks"
        git -C "$repo" config core.hooksPath custom-hooks
        foreign="$repo/custom-hooks/commit-msg"; expected=custom-hooks ;;
      destination) foreign="$repo/workshop/Tools/hooks/commit-msg"; expected="" ;;
    esac
    printf '#!/bin/sh\n# Foreign hook: keep me\nexit 0\n' > "$foreign"
    chmod +x "$foreign"
    cp "$foreign" "$WORK/expected-hook"
    output="$(adopt "$entry" "$repo" 2>&1)" || fail "$entry failed: $output"
    [[ $output == *'commit-msg hook collision'* ]] || fail "$entry did not explain $location collision: $output"
    [ "$(git -C "$repo" config core.hooksPath || true)" = "$expected" ] \
      || fail "$entry changed hooksPath despite $location collision"
    cmp "$foreign" "$WORK/expected-hook" || fail "$entry modified the foreign hook"
  done

  repo="$WORK/$entry-clean"
  fixture "$repo"
  adopt "$entry" "$repo" > "$WORK/output" 2>&1 || fail "$entry clean adoption failed"
  [ "$(git -C "$repo" config core.hooksPath)" = workshop/Tools/hooks ] \
    || fail "$entry did not enable hooks in a clean adopter"
  adopt "$entry" "$repo" > "$WORK/output" 2>&1 || fail "$entry repeat adoption failed"
  if grep -q 'commit-msg hook collision' "$WORK/output"; then fail "$entry called its own hook a collision"; fi
done

echo 'PASS: both hook adopters preserve foreign commit-msg hooks and enable clean adopters'
