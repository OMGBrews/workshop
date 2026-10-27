#!/usr/bin/env bash
# Keep interactive and login shells on the image's Claude PATH launcher.
# Run after ALL harness installers: Codex also prepends ~/.local/bin.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Tools/devcontainer/build/lib.sh
source "$BUILD_DIR/lib.sh"
[ -f "$HARNESS_MANIFEST" ] || {
    echo "ERROR: harness manifest is missing; finish setup before finalizing PATH." >&2
    exit 1
}
grep -qxF claude "$HARNESS_MANIFEST" || exit 0
test -x "$HOME/.local/share/workshop/bin/claude" || {
    echo "ERROR: Claude launcher was recorded but is not executable." >&2
    exit 1
}

python3 - <<'PY'
import os
from pathlib import Path
import stat
import tempfile

home = Path.home()
hook = 'case "$PATH" in "$HOME/.local/share/workshop/bin":*) ;; *) export PATH="$HOME/.local/share/workshop/bin:$PATH" ;; esac'
names = [".bashrc", ".zshrc", ".profile"]
# Never create a higher-priority login file that would hide an existing one.
names += [name for name in (".bash_profile", ".bash_login", ".zprofile", ".zlogin")
          if (home / name).is_file()]
for name in names:
    target = (home / name).resolve()
    old = target.read_text() if target.exists() else ""
    lines = [line for line in old.splitlines() if line != hook]
    new = "\n".join(lines) + ("\n" if lines else "") + hook + "\n"
    if new == old:
        continue
    mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o644
    fd, temporary = tempfile.mkstemp(prefix=".claude-path-", dir=target.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(new)
        os.chmod(temporary, mode)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
PY
echo "  Claude launcher PATH finalized after harness installation"
