#!/bin/bash
# Single source of truth for devcontainer configuration.
# Called during Docker build (COPY the directory + RUN this file). No runtime deps.
#
# This file is HARNESS-NEUTRAL. It does the container setup every project needs
# regardless of which coding assistant runs in it — git LFS filters, git config, the gh
# credential helper, the volume-workspace bootstrap hook — and then hands off to each
# harness-*.sh beside it. Anything specific to one coding harness belongs in that
# harness's file, never here.
#
# The split replaced a single Claude-only script. The README's "Harness scope:
# Claude-first by choice" section named the trigger for splitting it — a second harness
# self-hosting in these containers — and that trigger fired: Oh My Pi and Codex both
# run here now.
#
# Configures:
#   - Git LFS filter config (global, since no .git dir at build time)
#   - Git config (autocrlf, safe.directory, bind-mount stat handling) in the XDG
#     global file, leaving ~/.gitconfig free for the host copy (section 0)
#   - gh as git's credential helper for github.com HTTPS
#   - Volume-workspace auto-populate shell hook
#   - Every harness-*.sh in this directory (Claude Code, Oh My Pi, Codex)

set -euo pipefail

SETUP_SELF="${BASH_SOURCE[0]:?setup.sh must be run as a file (bash setup.sh), not piped on stdin: the harness lookup needs its own path}"
BUILD_DIR="$(cd "$(dirname "$SETUP_SELF")" && pwd)"

# shellcheck source=Tools/devcontainer/build/lib.sh
source "$BUILD_DIR/lib.sh"

echo "=== Devcontainer setup ==="

# 0. Where this script's git settings go, and why not ~/.gitconfig.
#
# Everything below writes with `git config --global`, and the global file is
# redirected here to the XDG path. The reason is identity. A container learns who
# you are from the Dev Containers extension, which copies the HOST's ~/.gitconfig
# in on attach — and it declines to populate a ~/.gitconfig that already exists.
# A kit that wrote its settings there at image-build time left that copy nowhere
# to land, so containers came up with no user.name and no user.email and could
# not commit until someone configured them by hand.
#
# So the kit's settings live in ~/.config/git/config and ~/.gitconfig is left
# absent for the host copy. Both are global scope; git reads the XDG file first
# and ~/.gitconfig second, so on any key set in both, the HOST wins. That is the
# intended precedence — your machine's git preferences beat the kit's defaults —
# and core.checkStat / core.trustctime (section 2) are the two worth knowing
# about if a host gitconfig ever carries them.
#
# GIT_CONFIG_GLOBAL is set explicitly rather than leaning on git's implicit rule
# (the XDG file is the write target only while ~/.gitconfig is absent) because
# this script is documented as safe to re-run live inside an attached container,
# where ~/.gitconfig DOES exist — the extension writes a credential helper into
# it on attach — and the implicit rule would put the kit's settings straight back
# into the file this arrangement keeps clear. The export dies with the script.
mkdir -p "$HOME/.config/git"
export GIT_CONFIG_GLOBAL="$HOME/.config/git/config"

# Recorded now, asserted after the last write (section 3): this script must never
# be the thing that creates ~/.gitconfig.
gitconfig_existed=0
if [ -e "$HOME/.gitconfig" ]; then
    gitconfig_existed=1
fi
echo "  git config target: $GIT_CONFIG_GLOBAL"

# 1. Git LFS filter config (equivalent to `git lfs install --global`)
git config --global filter.lfs.clean "git-lfs clean -- %f"
git config --global filter.lfs.smudge "git-lfs smudge -- %f"
git config --global filter.lfs.process "git-lfs filter-process"
git config --global filter.lfs.required true
echo "  Git LFS filters registered"

# 2. Git config. Contributor-neutral: the git identity is deliberately NOT set
# here — this kit ships in the public Workshop mirror, and a hard-coded
# maintainer identity is exactly the kind of personal default that must not.
# The private directory-copy build applies identity from the overlay sibling
# (section 2b); a public build stays anonymous and the user's first commit
# prompts for identity, which is the correct behavior for a contributor.
git config --global core.autocrlf input
git config --global safe.directory /workspace

# The macOS bind-mount filesystem returns stat metadata git does not trust, so a
# clean file reads as modified and a rebase pick dies with "Your local changes to
# the following files would be overwritten by merge" on a tree where both
# `git status --porcelain` and `git diff-files --name-only` print nothing.
# checkStat=minimal narrows the comparison to mtime and size, dropping ctime,
# inode, uid, gid and dev; trustctime=false drops ctime alone.
# Measured 2026-08-07 by the same fixture run seconds apart on both filesystems:
# on the bind mount (`fakeowner`) the phantom error, on overlay an honest
# `CONFLICT (content)`, and with these two settings the bind mount produced the
# honest conflict too. Set unconditionally rather than on detecting a bind mount:
# both are harmless on the volume-backed containers, which is cheaper than a
# detection branch that can be wrong.
git config --global core.checkStat minimal
git config --global core.trustctime false
echo "  Git config set"

# 2b. Optional private overlay. build/ is public — a contributor's build must
# stay anonymous — so personal defaults live in a sibling directory that only
# the PRIVATE directory-copy build carries into the image. A private Dockerfile
# COPYs <checkout>/Tools/devcontainer/overlay to /tmp/devcontainer-overlay (and
# sets DEVCONTAINER_OVERLAY_DIR); a live re-run from a private checkout finds
# the same directory as ../overlay beside this file. A public build has neither
# and skips the block.
#
# Git identity is NOT one of those defaults, in a private build either. Section
# 0 keeps ~/.gitconfig free so the Dev Containers extension can copy the HOST's
# identity in on attach; an overlay is sourced in-process here, so a
# `git config --global user.email` in one lands in the same XDG file every write
# above goes to, and on a host that carries no identity of its own that baked
# value is what every commit gets attributed to. Let the host supply it.
overlay_dir="${DEVCONTAINER_OVERLAY_DIR:-$BUILD_DIR/../overlay}"
if [ -d "$overlay_dir" ]; then
  overlay_applied=0
  for overlay in "$overlay_dir"/*.sh; do
    [ -f "$overlay" ] || continue
    # shellcheck disable=SC1090  # the overlay path is resolved at runtime
    # shellcheck disable=SC1091 # The optional private overlay is not public.
    source "$overlay"
    overlay_applied=1
    echo "  private overlay applied: $(basename "$overlay")"
  done
  [ "$overlay_applied" -eq 1 ] || echo "  overlay directory present but empty: $overlay_dir"
else
  echo "  no private overlay — public defaults only"
fi

# 3. Wire gh in as git's credential helper for github.com HTTPS, so that
# `git fetch`/`clone` of private repos reuses the gh token. We set this
# directly rather than via `gh auth setup-git` because gh is installed by a
# devcontainer feature that layers on *after* this build-time script — gh is
# not on PATH yet here. The helper is only invoked later, at fetch time, by
# which point gh and its token both exist. (`!gh ...` is resolved via PATH.)
git config --global --replace-all 'credential.https://github.com.helper' '!gh auth git-credential'
git config --global --replace-all 'credential.https://gist.github.com.helper' '!gh auth git-credential'
echo "  gh credential helper wired for github.com"

# 3b. The inheritance guarantee, asserted rather than assumed. An image whose
# build leaves a ~/.gitconfig behind is an image the host copy will skip, which
# is the whole failure section 0 exists to prevent — and it fails silently, at
# the first refused commit, in someone else's container weeks later. Nothing in
# the kit today can trip this: every write above goes through GIT_CONFIG_GLOBAL,
# sourced overlays included (they run in-process). It is here for the future edit
# that writes outside the export's reach — an explicit `--file ~/.gitconfig`, or
# a script run after the export goes out of scope.
#
# Only a build-time run can fail it. A live re-run inside an attached container
# finds ~/.gitconfig already present (the extension put a credential helper
# there) and is deliberately left alone.
if [ "$gitconfig_existed" -eq 0 ] && [ -e "$HOME/.gitconfig" ]; then
    echo "ERROR: this setup run created $HOME/.gitconfig, which must stay absent so" >&2
    echo "       the Dev Containers host-gitconfig copy has somewhere to land on" >&2
    echo "       attach. Something wrote outside GIT_CONFIG_GLOBAL — an explicit" >&2
    echo "       'git config --file', or a script that ran after the export in" >&2
    echo "       section 0 went out of scope. Route that write through --global." >&2
    exit 1
fi

# 4. Volume-workspace auto-populate on first interactive shell. Two reasons this
# hangs off the shell rather than devcontainer lifecycle hooks: Windsurf/Devin's
# dev-containers fork never runs postCreate/postStart at all, and even in stock
# clients those hooks run before the IDE's git credential forwarding exists. An
# interactive terminal is the one context guaranteed to have both credentials
# and a human watching. Inert unless the project's devcontainer.json sets
# WORKSPACE_REPO_URL in containerEnv; retries on every new shell until the
# workspace is populated.
# shellcheck disable=SC2016  # single quotes are the point: this text is written verbatim
# into the rc files and must expand when a shell starts, not while this script runs.
BOOTSTRAP_HOOK='[ -n "${WORKSPACE_REPO_URL:-}" ] && [ ! -e "${WORKSPACE_DIR:-/workspace}/.git/devcontainer-populate-done" ] && [ -x /usr/local/bin/workspace-bootstrap.sh ] && bash /usr/local/bin/workspace-bootstrap.sh create; true'
while IFS= read -r rcfile; do
    if [ -f "$rcfile" ] && grep -qF 'workspace-bootstrap.sh' "$rcfile"; then
        continue
    fi
    echo "$BOOTSTRAP_HOOK" >> "$rcfile"
done < <(harness_rcfiles)
echo "  workspace auto-populate shell hook installed"

# 5. Coding harnesses.
#
# The manifest is truncated here and appended to by each harness script, so it always
# describes THIS run rather than accumulating across re-runs — a harness file deleted
# from the kit disappears from the manifest on the next build instead of lingering as a
# claim the image no longer honours.
: > "$HARNESS_MANIFEST"

# Discovered by glob, never listed. A hard-coded list is the shape that made the
# previous single-harness kit expensive to extend: adding a harness would mean editing
# this file, the validator, and hq's drift bake. Globbing here — paired with the
# directory-digest entry in hq's drift bake — means a new harness-<name>.sh is picked
# up, validated, and drift-tracked by dropping in one file.
harness_count=0
for harness in "$BUILD_DIR"/harness-*.sh; do
    [ -e "$harness" ] || break   # nullglob is not set; an unmatched glob is literal
    echo "--- $(basename "$harness")"
    bash "$harness"
    harness_count=$((harness_count + 1))
done

# Zero harnesses is a broken build context, not a minimal one. Every consuming Dockerfile
# COPYs this whole directory, so an empty glob means the COPY delivered a partial tree —
# and a container that silently ships with no coding assistant is precisely the
# reports-success-while-doing-nothing failure signal-hygiene.md is about.
if [ "$harness_count" -eq 0 ]; then
    echo "ERROR: no harness-*.sh found beside setup.sh (looked in $BUILD_DIR)." >&2
    echo "       A Dockerfile must COPY the whole build/ directory, not setup.sh alone." >&2
    exit 1
fi

# Installers may prepend native binary paths in shell startup files. Run
# harness-owned finalizers only after every installer has finished.
for finalizer in "$BUILD_DIR"/finalize-*.sh; do
    [ -f "$finalizer" ] || break
    bash "$finalizer"
done

echo "  $harness_count harness(es) configured: $(tr '\n' ' ' < "$HARNESS_MANIFEST")"
echo "=== Devcontainer setup complete ==="
