#!/usr/bin/env bash
# Configure Workshop's hooks without replacing an existing commit-msg hook.
# Usage: bash configure-workshop-hooks.sh <repo-root> <repo-relative-hooks-dir>
# Exit 1 reports a collision and leaves both configuration and files intact.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <repo-root> <repo-relative-hooks-dir>" >&2
  exit 2
fi
repo="$(cd "$1" && pwd -P)"
hooks=$2
case "$hooks" in
  /*) destination="$hooks/commit-msg" ;;
  *) destination="$repo/$hooks/commit-msg" ;;
esac

# A foreign installer may already have written into the shared hooks directory.
# Never bless it as Workshop's check or overwrite it while configuring adoption.
if [ -e "$destination" ] || [ -L "$destination" ]; then
  if ! grep -qFx '# Workshop commit-msg hook' "$destination"; then
    echo "warning: commit-msg hook collision at $destination; preserved the hook and core.hooksPath. Resolve the collision before enabling Workshop attribution checks." >&2
    exit 1
  fi
fi

active="$(git -C "$repo" rev-parse --path-format=absolute --git-path hooks/commit-msg)"
case "$active" in
  /*) ;;
  *) active="$repo/$active" ;;
esac
if [ -x "$active" ] && [ "$(readlink -f "$active")" != "$(readlink -m "$destination")" ]; then
  echo "warning: active commit-msg hook collision at $active; preserved the hook and core.hooksPath. Integrate it explicitly before enabling Workshop attribution checks." >&2
  exit 1
fi

git -C "$repo" config core.hooksPath "$hooks"
