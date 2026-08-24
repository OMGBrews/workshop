#!/usr/bin/env bash
#
# sync-skill-symlinks.sh — regenerate a project's per-skill shared-skill symlinks
#
# Each OMG Brews project consumes the shared skills in devtools by symlinking
# them in. Historically that was a single directory-level symlink
# (.claude/skills -> ../devtools/.claude/skills), which makes it impossible to
# add a project-specific skill alongside the shared ones.
#
# This script creates (or refreshes) PER-SKILL symlinks, on TWO surfaces:
#
#   .agents/skills/<name> -> ../../<mount>/.agents/skills/<name>   canonical
#   .claude/skills/<name> -> ../../.agents/skills/<name>            Claude Code bridge
#
# .agents/skills/ is the Agent Skills open standard's path, which every harness
# scans; .claude/skills/ is Claude Code's, and it chains through the canonical
# link rather than reaching into devtools a second time. Writing only the vendor
# surface is what left every non-Claude harness finding no shared skills at all,
# so both are written, always, and the canonical one is written first — the
# bridge points at it.
#
# The tree is found by discovery, not by name: this script ships inside the tree
# it looks for (at <tree>/Tools/), so the script's own physical location finds
# it. That works for the upstream layout and for any consumer mounting the tree
# under another name (workshop/ and beyond). When the script's own tree lives
# OUTSIDE the target repo — the propagation case, where a fleet copy syncs
# another checkout — the name is re-derived at the repo root.
#
# The tree and the MOUNT are not always the same directory. A consumer mounts a
# directory at its own root, and that directory is the only one its links may
# name; a tree nested deeper inside it — a private wrapper that nests this
# repository as a submodule — is the wrapper's business, not the consumer's. So
# the mount is the TOP-LEVEL directory under the repo root, and the tree may sit
# anywhere beneath it. The one derived mount feeds both the source directory and
# the link targets, so the two can never disagree.
#
# Usage:
#   sync-skill-symlinks.sh [REPO_ROOT]
#
#   REPO_ROOT  Directory containing .claude/ (or .agents/) and the mounted
#              shared tree (default: cwd).
#
# Behaviour, applied to each surface independently:
#   - Converts a directory-level symlink into a real directory.
#   - Creates/refreshes one symlink per shared skill (idempotent).
#   - Leaves project-specific skills (real directories) untouched.
#   - On a name collision (a project skill named like a shared skill), keeps the
#     project skill, skips the shared link, and warns.
#   - Removes stale links that point at a shared-skill path but no longer
#     resolve — including links left over from the pre-2026-08 layout, whose
#     targets still read .../devtools/.claude/skills/<name>.
#   - Verifies every link it is responsible for resolves to a readable SKILL.md.
#
# Then, on the bridge surface only, it regenerates .claude/skills/README.md — the
# signpost telling the next reader that this folder is symlinks and that skills
# are authored in .agents/skills/. Generated, so the fleet cannot drift into N
# different versions of that sentence.
#
# Exit status: 0 on success (even with warnings), non-zero on a usage/layout
# error or an unresolvable link on either surface.

set -euo pipefail
shopt -s nullglob   # an empty skills dir must expand to nothing, not a literal '*'

REPO_ROOT="${1:-$PWD}"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ -d "$REPO_ROOT/.claude" ] || [ -d "$REPO_ROOT/.agents" ] \
  || err "no .claude/ or .agents/ under $REPO_ROOT"

# Physical, absolute: the mount comparison below needs both sides real, and $1
# may be relative or reach the repo through a symlink.
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"

# Resolve the tree, then the mount. Step 1, self-location: the script ships at
# <tree>/Tools/sync-skill-symlinks.sh, so the parent of its own physical
# directory is the tree — whatever it is named — when it lies inside REPO_ROOT.
# Step 2, basename fallback: a script invoked from some OTHER checkout (fleet
# propagation) has its tree outside the target repo, so re-derive the name at
# the repo root. Step 3: fail, naming every path checked.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_MOUNT="$(dirname "$SCRIPT_DIR")"

# TREE_REL is where the tree sits relative to the repo root — one component for
# a directly mounted tree, two for a tree nested inside a wrapper. MOUNT_DIR is
# its FIRST component: the directory the consumer actually mounted, and so the
# only one its relative links may traverse. Taking the tree itself here is what
# used to write `../../<tree-basename>/...` from a consuming root that has no
# such directory — links that dangle, are swept as stale by step 3 of
# sync_surface, and leave the surface empty while the run reports success.
case "$SCRIPT_MOUNT" in
  "$REPO_ROOT")
    TREE_REL=""; MOUNT_DIR="$REPO_ROOT" ;;
  "$REPO_ROOT"/*)
    TREE_REL="${SCRIPT_MOUNT#"$REPO_ROOT"/}"
    MOUNT_DIR="$REPO_ROOT/${TREE_REL%%/*}" ;;
  *)
    TREE_REL="$(basename "$SCRIPT_MOUNT")"
    MOUNT_DIR="$REPO_ROOT/$TREE_REL" ;;
esac

[ "$MOUNT_DIR" = "$REPO_ROOT" ] \
  && err "refusing to run inside the shared tree itself ($REPO_ROOT) — every shared skill would be linked onto itself; run this from the project repo that consumes the shared skills"

# The roster is read from the MOUNT, not from the tree. For a directly mounted
# tree they are the same directory. For a wrapper that nests this repository,
# the wrapper's own surface is the one the consumer links to — it carries the
# shared skills as links into the nested tree plus any the wrapper owns
# outright, and which is which is not the consumer's concern.
SRC_DIR="$MOUNT_DIR/.agents/skills"
MOUNT_NAME="$(basename "$MOUNT_DIR")"

[ -d "$SRC_DIR" ] || err "no shared skills found — checked .agents/skills/ under '$MOUNT_DIR' (the mount at the repo root) for a tree found at '$SCRIPT_MOUNT'; the shared skills are not present under either"

dangling=0

# sync_surface <skills-dir> <relative-target-prefix> <label>
sync_surface() {
  local skills_dir="$1" rel_prefix="$2" label="$3"
  local created=0 refreshed=0 collisions=0 removed=0
  local src name dst want target

  # 1. If the skills dir is a directory-level symlink, replace it with a real dir.
  if [ -L "$skills_dir" ]; then
    rm "$skills_dir"
    echo "converted directory-level symlink to a real directory: $skills_dir"
  fi
  mkdir -p "$skills_dir"

  # 2. Create / refresh one symlink per shared skill.
  for src in "$SRC_DIR"/*/; do
    name="$(basename "$src")"
    dst="$skills_dir/$name"
    if [ -d "$dst" ] && [ ! -L "$dst" ]; then
      echo "warning: project-specific skill '$name' shadows the shared skill of the same name — keeping the project skill, skipping the shared link" >&2
      collisions=$((collisions + 1))
      continue
    fi
    want="$rel_prefix/$name"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$want" ]; then
      refreshed=$((refreshed + 1))
    else
      ln -sfn "$want" "$dst"
      created=$((created + 1))
    fi
  done

  # 3. Remove stale links: symlinks aimed at a shared-skill path that no longer
  #    resolve. Both target shapes are swept — the canonical/bridge ones this
  #    script writes today, and the pre-move ../../devtools/.claude/skills/<name>
  #    that a repo synced by an older devtools still carries. A repo bumped past
  #    the move but never re-synced would otherwise keep a link that resolves
  #    only by accident of the compatibility bridge.
  for dst in "$skills_dir"/*; do
    [ -L "$dst" ] || continue
    target="$(readlink "$dst")"
    case "$target" in
      */devtools/.claude/skills/*|*/.agents/skills/*)
        if [ ! -e "$dst" ]; then rm "$dst"; removed=$((removed + 1)); fi
        ;;
    esac
  done

  # 4. Verify every shared link actually resolves to a real skill.
  #    A dangling symlink is created without error and looks fine under `ls` — it
  #    only fails at skill-invocation time as "Unknown skill". Check with test -e,
  #    never a visual scan. (Catches an uninitialized devtools submodule or any
  #    layout where the relative prefix would be wrong.)
  for src in "$SRC_DIR"/*/; do
    name="$(basename "$src")"
    dst="$skills_dir/$name"
    [ -L "$dst" ] || continue                       # skipped as a collision; not ours to verify
    if [ ! -e "$dst" ] || [ ! -r "$dst/SKILL.md" ]; then
      echo "error: link does not resolve to a readable skill: $dst -> $(readlink "$dst")" >&2
      dangling=$((dangling + 1))
    fi
  done

  # 5. Report this surface.
  echo "synced $skills_dir ($label): ${created} linked, ${refreshed} already current, ${removed} stale removed, ${collisions} collision(s)"
  [ "$collisions" -gt 0 ] && echo "  (review collisions above; rename the project skill if it should not shadow a shared one)"
  return 0
}

# The bridge folder's signpost. It is GENERATED rather than hand-written in
# each repo for the reason every duplicate here is: one canonical text beats N
# copies drifting apart, and rewriting it on every run means a local edit heals
# at the next sync instead of surviving as a private fork. It lands only on the
# vendor surface — .agents/skills/ is the real thing and needs no sign saying
# where the real thing is.
#
# The text is a quoted heredoc so its Markdown backticks stay literal, and the
# tree path is substituted afterwards: the command a reader should run names
# wherever this tree is actually mounted (workshop/ in a project, a nested
# workshop-dev/workshop in hq), never a guess.
write_bridge_readme() {
  local path="$REPO_ROOT/.claude/skills/README.md" tmp
  tmp="$path.tmp.$$"
  sed "s|@TREE@|${TREE_REL:-.}|g" > "$tmp" <<'READMEEOF'
# Skills — the Claude Code bridge

Every entry beside this file is a symlink, and this folder holds no skills of
its own. The real skill directories live at `.agents/skills/<name>/` in the
repository root — the Agent Skills open standard's discovery path, which every
harness scans. `.claude/skills/` bridges to it with one
`<name> -> ../../.agents/skills/<name>` link per skill, so Claude Code and every
other harness run the same skill from one source.

## Author skills in `.agents/skills/`, never here

A real skill directory under `.claude/skills/` is a skill only one harness can
run. Since skills are where our process lives, that is the most expensive
mistake on this surface, and check 8 of
`@TREE@/Tools/check-agent-surfaces.sh` fails on it by design.

This holds for a project-local skill as much as a shared one: the real directory
belongs in `.agents/skills/`, with a bridge link here beside the shared ones.

## Regenerating the links

Add, rename, or remove a shared skill in the mounted tree, then regenerate both
surfaces from the repository root:

```bash
bash @TREE@/Tools/sync-skill-symlinks.sh .
```

The generator writes the canonical surface first and the bridge second, drops
links that no longer resolve, and leaves real skill directories alone.

---

This file is generated by that script — edit the text in
`@TREE@/Tools/sync-skill-symlinks.sh`, since a copy edited here is
overwritten on the next run.
READMEEOF
  if [ -f "$path" ] && [ ! -L "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    echo "bridge README.md already current: $path"
  else
    mv -f "$tmp" "$path"
    echo "wrote bridge README.md: $path"
  fi
}

# Roster-staleness seam. This script's own run can land mid-session — a
# consumer syncing while a session is open — and no harness refresh observes
# it. Compare the skill entry set before and after, and say so when it
# changed, so the operator gets the reload instruction exactly when this run
# made it necessary. Also wire the git hooks (core.hooksPath) that carry the
# same warning for FUTURE tree-changing git operations — a manual pull of an
# already-prepared consumer commit never runs this script, so the hooks are
# the seam that covers that route (Tools/check-skill-roster-freshness.sh).
roster_check="$SCRIPT_DIR/check-skill-roster-freshness.sh"
roster_before="$(bash "$roster_check" print 2>/dev/null)" || roster_before=""
roster_changed() { # prints the reload instruction, once, when the set changed
  [ -n "$roster_before" ] || return 0
  [ "$roster_before" = "$(bash "$roster_check" print 2>/dev/null)" ] && return 0
  echo "warning: the shared skill entry set changed — a session already open in this repo is serving stale skill names; run /reload-skills (Claude Code) or /reload (Oh My Pi)"
}

# Canonical first: the bridge's links point into it, so syncing the bridge
# against a not-yet-written .agents/skills would report every link dangling.
sync_surface "$REPO_ROOT/.agents/skills" "../../$MOUNT_NAME/.agents/skills" "canonical"
sync_surface "$REPO_ROOT/.claude/skills" "../../.agents/skills" "Claude Code bridge"
write_bridge_readme

roster_changed
# core.hooksPath names the TREE, not the mount: Tools/hooks/ is a real directory
# in this repository, and a wrapper that nests it does not restage it at its own
# root. TREE_REL is already repo-root-relative, which is the form the config key
# wants, so no realpath is needed to produce it.
if [ -f "$roster_check" ]; then
  hooks_rel="$TREE_REL/Tools/hooks"
  [ -d "$REPO_ROOT/$hooks_rel" ] && git -C "$REPO_ROOT" config core.hooksPath "$hooks_rel"
fi

if [ "$dangling" -gt 0 ]; then
  echo "FAILED: ${dangling} shared skill link(s) do not resolve — see errors above" >&2
  exit 1
fi
exit 0
