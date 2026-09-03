#!/bin/bash
# Connect to a project's dev container.
# Run from the host machine inside any project that has a .devcontainer/:
#
#   bash workshop/Tools/devcontainer/connect.sh
#
# Reads the container name from --name in runArgs in devcontainer.json
# and opens a login shell in the container.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Walk up from <mount>/Tools/devcontainer/ to the project root — the mount name
# is never read, only its depth
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

DEVCONTAINER_JSON="$PROJECT_ROOT/.devcontainer/devcontainer.json"
if [ ! -f "$DEVCONTAINER_JSON" ]; then
  echo "No .devcontainer/devcontainer.json found at $PROJECT_ROOT" >&2
  exit 1
fi

# Extract the container name. Two supported sources:
#   1. "--name=<name>" in runArgs (build/image-based devcontainers) — what every
#      devcontainer in this workspace uses, and what the volume-workspace template
#      ships.
#   2. "container_name: <name>" in .devcontainer/docker-compose.yml, for
#      compose-based devcontainers. No repo in this workspace has one, so this
#      branch is unexercised here; it is kept for compose projects, not as a
#      workaround for any editor.
#
# This comment used to call compose "required for Cursor, whose Dev Containers build
# hangs on a pinned --name in runArgs". That claim was written untested (2026-06-06,
# 7317517) and is false as tested on 2026-08-06: Cursor 3.14.27 with the Anysphere
# Dev Containers fork (anysphere.remote-containers 1.0.38) built a devcontainer pinned
# "--name=cursor-pin-test", reattached to it on a later reopen, and `docker ps` confirmed
# the container really carried the pinned name — so the pin was honoured, not ignored.
# Scoped to that version deliberately: an earlier Cursor may well have had the bug.
#
# Every extraction below ends in `|| true`, and that is load-bearing under
# `set -euo pipefail`: a no-match `grep` exits 1, `pipefail` hands that status to
# the whole pipeline, and a bare assignment takes its command substitution's
# status — so `set -e` killed the script *at the assignment*, printing nothing at
# all. The "not found" messages and the compose fallback below were unreachable
# code: the exact shape signal-hygiene.md warns about, since exit 1 with no
# output reads as "ran and declined" rather than "died before deciding".
CONTAINER=$(grep -o '"--name=[^"]*"' "$DEVCONTAINER_JSON" \
  | head -1 \
  | sed 's/"--name=\([^"]*\)"/\1/' || true)

if [ -z "$CONTAINER" ]; then
  for COMPOSE in "$PROJECT_ROOT/.devcontainer/docker-compose.yml" "$PROJECT_ROOT/.devcontainer/docker-compose.yaml"; do
    [ -f "$COMPOSE" ] || continue
    CONTAINER=$(grep -E '^[[:space:]]*container_name:' "$COMPOSE" \
      | head -1 \
      | sed -E 's/^[[:space:]]*container_name:[[:space:]]*//; s/["'"'"']//g; s/[[:space:]]*$//' || true)
    [ -n "$CONTAINER" ] && break
  done
fi

if [ -z "$CONTAINER" ]; then
  echo "No container name found." >&2
  echo "Add \"--name=your-project\" to runArgs in $DEVCONTAINER_JSON," >&2
  echo "or \"container_name: your-project\" to .devcontainer/docker-compose.yml" >&2
  exit 1
fi

# Extract workspaceFolder (default to /workspace)
WORKSPACE=$(grep -o '"workspaceFolder"[[:space:]]*:[[:space:]]*"[^"]*"' "$DEVCONTAINER_JSON" \
  | head -1 \
  | sed 's/.*"workspaceFolder"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
WORKSPACE="${WORKSPACE:-/workspace}"

# Extract remoteUser (default to vscode). Projects that build on a base image
# with a different non-root user (e.g. the "node" devcontainer image) set
# "remoteUser" accordingly; honor it instead of assuming vscode.
REMOTE_USER=$(grep -o '"remoteUser"[[:space:]]*:[[:space:]]*"[^"]*"' "$DEVCONTAINER_JSON" \
  | head -1 \
  | sed 's/.*"remoteUser"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
REMOTE_USER="${REMOTE_USER:-vscode}"

# Three different failures reach the same `docker inspect` non-zero exit, and
# collapsing them into "is the dev container running?" sends you looking at the
# container when the real answer is "you are not on the host" (this script must
# run from the host — inside a dev container there is no docker at all) or "the
# daemon is down". Separate them before suppressing any output.
if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found on PATH." >&2
  echo "Run this from the HOST machine, not from inside a dev container." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Cannot reach the Docker daemon. Is Docker Desktop running?" >&2
  exit 1
fi
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Container '$CONTAINER' not found. Is the dev container running?" >&2
  echo "Open the project in VS Code and 'Reopen in Container', or check:" >&2
  echo "  docker ps -a --filter name=$CONTAINER" >&2
  exit 1
fi

EXEC_ARGS=(
  docker exec -it
  -u "$REMOTE_USER"
  -w "$WORKSPACE"
  -e TERM=xterm-256color
  -e LANG=en_US.UTF-8
  -e LC_ALL=en_US.UTF-8
  -e COLORTERM=truecolor
  "$CONTAINER"
)

"${EXEC_ARGS[@]}" bash -li
