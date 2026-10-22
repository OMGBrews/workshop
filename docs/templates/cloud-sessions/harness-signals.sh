#!/usr/bin/env bash
# Canonical session detector. Bootstrap adopters carry a checked, byte-identical
# copy at scripts/lib/harness-signals.sh because the mount may not exist yet.
# Execute for one protocol line; source for silent, exported compatibility values.
# Do not change the caller's shell options, directory, or positional arguments.

agent_detect_session() {
  local requested="${1:-}" declared="${AGENT_SESSION_ENVIRONMENT:-}"
  local remote="${AGENT_SESSION_REMOTE:-}" ephemeral="${AGENT_SESSION_EPHEMERAL:-}"
  local claude="${CLAUDE_CODE_REMOTE:-}" name value evidence="" cloud=false
  local result=unknown source=none disposable=false rc=0

  # An explicit command argument is the user's override, not auto-detection.
  if [[ -n "$requested" ]]; then
    case "$requested" in
      local|cloud) result="$requested"; source=argument ;;
      *) source=invalid_argument; rc=2 ;;
    esac
  else
    case "$declared" in
      ''|unknown|local|cloud) ;;
      *) source=invalid_AGENT_SESSION_ENVIRONMENT; rc=2 ;;
    esac
    for name in AGENT_SESSION_REMOTE AGENT_SESSION_EPHEMERAL CLAUDE_CODE_REMOTE; do
      case "$name" in
        AGENT_SESSION_REMOTE) value="$remote" ;;
        AGENT_SESSION_EPHEMERAL) value="$ephemeral" ;;
        CLAUDE_CODE_REMOTE) value="$claude" ;;
      esac
      case "$value" in
        true) cloud=true; evidence="${evidence:+$evidence,}$name" ;;
        ''|false|unknown) ;;
        *) source="invalid_$name"; rc=2 ;;
      esac
    done
    if [[ "$rc" == 0 ]]; then
      if [[ "$declared" == local && "$cloud" == true ]]; then
        source="conflict:AGENT_SESSION_ENVIRONMENT,$evidence"; rc=2
      elif [[ "$declared" == local || "$declared" == cloud ]]; then
        result="$declared"; source=AGENT_SESSION_ENVIRONMENT
        [[ -z "$evidence" ]] || source="$source,$evidence"
      elif [[ "$cloud" == true ]]; then
        result=cloud; source="$evidence"
      fi
      # Cloud is a location, not permission to fast-forward a disposable tree.
      # Preserve the existing bootstrap capability only on its positive signals.
      if [[ "$rc" == 0 && "$result" == cloud && ( "$ephemeral" == true || ( -z "$ephemeral" && "$claude" == true ) ) ]]; then
        disposable=true
      fi
    fi
  fi

  AGENT_SESSION_ENVIRONMENT="$result"
  AGENT_SESSION_SIGNAL="$source"
  case "$result" in
    local) AGENT_SESSION_REMOTE=false ;;
    cloud) AGENT_SESSION_REMOTE=true ;;
    *) AGENT_SESSION_REMOTE=unknown ;;
  esac
  AGENT_SESSION_EPHEMERAL="$disposable"
  export AGENT_SESSION_ENVIRONMENT AGENT_SESSION_SIGNAL AGENT_SESSION_REMOTE AGENT_SESSION_EPHEMERAL
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  detector_rc=0
  if [[ "$#" == 0 ]]; then
    agent_detect_session || detector_rc=$?
  elif [[ "$#" == 2 && "$1" == --environment && ( "$2" == local || "$2" == cloud ) ]]; then
    agent_detect_session "$2" || detector_rc=$?
  else
    printf '%s\n' 'usage: harness-signals.sh [--environment local|cloud]' >&2
    exit 2
  fi
  printf 'environment=%s signal=%s\n' "$AGENT_SESSION_ENVIRONMENT" "$AGENT_SESSION_SIGNAL"
  exit "$detector_rc"
else
  agent_detect_session
fi
