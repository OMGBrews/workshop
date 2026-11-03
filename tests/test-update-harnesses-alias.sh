#!/usr/bin/env bash
# Exercise neutral setup and fresh interactive shells without updating assistants.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/build" "$WORK/home" "$WORK/bin"
cp "$ROOT/Tools/devcontainer/build/"{setup.sh,lib.sh} "$WORK/build/"
# Setup discovers a harness, but this fixture must never install real assistants.
echo ':' > "$WORK/build/harness-fixture.sh"
export HOME="$WORK/home"
export DEVCONTAINER_OVERLAY_DIR="$WORK/no-overlay"
export WORKSPACE_DIR="$WORK/build-time-root"
bash "$WORK/build/setup.sh"
bash "$WORK/build/setup.sh"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ "$(grep -c '^alias update-harnesses=' "$rc")" -eq 1 ]
done

# Intercept bash only when the alias invokes it. This checks the exact runtime
# argument, including the default root, without modifying /workspace's checkout.
cat > "$WORK/bin/bash" <<'STUB'
#!/bin/sh
[ "$#" -eq 1 ] || exit 10
[ "$1" = "$EXPECTED_SCRIPT" ] || exit 11
if [ "$1" != /workspace/workshop/Tools/devcontainer/update-harnesses.sh ]; then
    exec /bin/bash "$1"
fi
printf 'runtime updater: %s\n' "$1"
STUB
chmod +x "$WORK/bin/bash"
for shell in bash zsh; do
    shell_path="$(command -v "$shell")"
    for root in default "$WORK/runtime" "$WORK/root with spaces"; do
        if [ "$root" = default ]; then
            unset WORKSPACE_DIR
            expected=/workspace
        else
            export WORKSPACE_DIR="$root"
            expected="$root"
            mkdir -p "$root/workshop/Tools/devcontainer"
            cat > "$root/workshop/Tools/devcontainer/update-harnesses.sh" <<'UPDATER'
#!/usr/bin/env bash
printf 'runtime updater: %s\n' "${BASH_SOURCE[0]}"
UPDATER
        fi
        export EXPECTED_SCRIPT="$expected/workshop/Tools/devcontainer/update-harnesses.sh"
        # Change the root AFTER startup: expansion must happen at invocation.
        export INVOCATION_ROOT="$expected"
        export WORKSPACE_DIR="$WORK/startup-root"
        # shellcheck disable=SC2016 # The child shell expands its environment.
        out="$(PATH="$WORK/bin:$PATH" ZDOTDIR="$HOME" "$shell_path" -ic 'export WORKSPACE_DIR="$INVOCATION_ROOT"; eval update-harnesses' 2>&1)"
        [[ "$out" == *"runtime updater: $EXPECTED_SCRIPT"* ]]
        if [ "$root" = default ]; then
            out="$(PATH="$WORK/bin:$PATH" ZDOTDIR="$HOME" "$shell_path" -ic 'unset WORKSPACE_DIR; eval update-harnesses' 2>&1)"
            [[ "$out" == *"runtime updater: $EXPECTED_SCRIPT"* ]]
        fi
    done
done

# A user's replacement survives setup as well.
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    sed -i '/^alias update-harnesses=/c\alias update-harnesses="echo custom"' "$rc"
done
bash "$WORK/build/setup.sh"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ "$(grep -c '^alias update-harnesses=' "$rc")" -eq 1 ]
    grep -qx 'alias update-harnesses="echo custom"' "$rc"
done
echo "PASS: update-harnesses alias installation and runtime resolution"
