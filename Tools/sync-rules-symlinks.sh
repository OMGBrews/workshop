#!/usr/bin/env bash
#
# sync-rules-symlinks.sh — write a repository's standing-rule links for Claude Code
#
# Claude Code loads every Markdown file in .claude/rules/ at launch, and reads
# AGENTS.md natively as long as no CLAUDE.md sits in or above the repository. So
# the three Workshop standing rules reach a Claude session as three symlinks into
# the mounted Workshop, with no wrapper file at all:
#
#   .claude/rules/signal-hygiene.md           -> ../../<mount>/docs/signal-hygiene.md
#   .claude/rules/definition-of-done.md       -> ../../<mount>/docs/definition-of-done.md
#   .claude/rules/verification-terminology.md -> ../../<mount>/docs/verification-terminology.md
#
# Workshop itself has no mount; there the links read ../../docs/<rule>.md.
#
# The tree is found the way Tools/sync-skill-symlinks.sh finds it, and the logic
# is duplicated here rather than sourced, because propagation copies this script
# into other checkouts as a single file. Step 1, self-location: the script ships
# at <tree>/Tools/, so the parent of its own physical directory is the tree when
# it lies inside REPO_ROOT, and the mount is the tree's first path component
# under the root. Step 2, basename fallback: a script run from some other
# checkout has its tree outside REPO_ROOT, so the mount is re-derived as the
# tree's basename at the root. Where the tree IS the root — Workshop converting
# itself — the links name ../../docs instead.
#
# One layout is refused: a tree more than one component below the root, the
# shape of a consumer mounting a wrapper that nests Workshop. The rule documents
# live in the nested tree, not in the mount, and check 2 of
# Tools/check-agent-surfaces.sh accepts exactly one mount component.
#
# Usage:
#   sync-rules-symlinks.sh [REPO_ROOT]
#
#   REPO_ROOT  The repository root, holding AGENTS.md and the mounted tree
#              (default: cwd).
#
# Behaviour:
#   - Creates .claude/rules/ and one symlink per standing rule (idempotent).
#   - Owns only symlinks whose target reads ../../<one-component>/docs/<name>.md,
#     or ../../docs/<name>.md when the tree is the root, and removes owned links
#     that no longer resolve.
#   - Never touches a real file or a symlink with any other target: real topic
#     files hold Claude-only content, and a repo-local rule link
#     (../../docs/<name>.md in a consumer) is written by hand and tracked.
#   - Verifies every standing-rule link resolves and opens with its heading.
#
# Exit status: 0 on success, 1 on a usage or layout error, a path it will not
# overwrite, or a standing-rule link that does not resolve to its rule.

set -euo pipefail
shopt -s nullglob   # an empty rules dir must expand to nothing, not a literal '*'

REPO_ROOT="${1:-$PWD}"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ -d "$REPO_ROOT" ] || err "no such directory: $REPO_ROOT"
[ -f "$REPO_ROOT/AGENTS.md" ] \
  || err "no AGENTS.md under $REPO_ROOT — run this from the repository root that carries the instructions"

# Physical, absolute: the tree comparison below needs both sides real, and $1
# may be relative or reach the repo through a symlink.
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TREE="$(dirname "$SCRIPT_DIR")"

case "$TREE" in
  "$REPO_ROOT")
    PREFIX="../../docs" ;;
  "$REPO_ROOT"/*)
    TREE_REL="${TREE#"$REPO_ROOT"/}"
    case "$TREE_REL" in
      */*) err "the tree at '$TREE_REL' is nested below the mount '${TREE_REL%%/*}' — the rule documents live in the nested tree, and a rules link names one mount component; run this from a repository that mounts the tree directly" ;;
    esac
    PREFIX="../../$TREE_REL/docs" ;;
  *)
    PREFIX="../../$(basename "$TREE")/docs" ;;
esac

RULES_DIR="$REPO_ROOT/.claude/rules"
DOCS_DIR="$REPO_ROOT/${PREFIX#../../}"
STANDING_RULES="signal-hygiene definition-of-done verification-terminology"

rule_heading() {
  case "$1" in
    signal-hygiene) printf '# Signal hygiene' ;;
    definition-of-done) printf '# Definition of done' ;;
    verification-terminology) printf '# Verification terminology' ;;
  esac
}

# Is this symlink target one this script owns? ../../<mount>/docs/<name>.md with
# exactly one mount component, or ../../docs/<name>.md where the tree is the root.
owned_target() {
  local t=$1 mount name
  case "$t" in
    ../../*/docs/*.md)
      mount="${t#../../}"; mount="${mount%%/*}"
      name="${t#../../"$mount"/docs/}"
      case "$mount" in . | .. | docs) return 1 ;; esac
      case "$name" in */*) return 1 ;; esac
      return 0 ;;
    ../../docs/*.md)
      [ "$PREFIX" = "../../docs" ] || return 1
      name="${t#../../docs/}"
      case "$name" in */*) return 1 ;; esac
      return 0 ;;
  esac
  return 1
}

[ -d "$DOCS_DIR" ] \
  || err "no standing rules found — $DOCS_DIR is not a directory (is the mount populated?)"
mkdir -p "$RULES_DIR"

created=0; current=0; removed=0; problems=0

# 1. Remove owned links that no longer resolve — a renamed mount, a retired rule.
for dst in "$RULES_DIR"/*; do
  [ -L "$dst" ] || continue
  owned_target "$(readlink "$dst")" || continue
  if [ ! -e "$dst" ]; then
    rm "$dst"
    removed=$((removed + 1))
  fi
done

# 2. Create or refresh one link per standing rule.
for rule in $STANDING_RULES; do
  dst="$RULES_DIR/$rule.md"
  want="$PREFIX/$rule.md"
  if [ -L "$dst" ]; then
    got="$(readlink "$dst")"
    if [ "$got" = "$want" ]; then
      current=$((current + 1))
      continue
    fi
    if ! owned_target "$got"; then
      echo "error: $dst -> $got is a symlink this script does not own — remove it, then re-run" >&2
      problems=$((problems + 1))
      continue
    fi
  elif [ -e "$dst" ]; then
    echo "error: $dst is a real file — a standing rule is linked, never copied; remove it, then re-run" >&2
    problems=$((problems + 1))
    continue
  fi
  ln -sfn "$want" "$dst"
  created=$((created + 1))
done

# 3. Verify. A dangling symlink is created without error and looks fine under
#    ls; a session would simply run without the rule. Check with test -r and the
#    rule's heading, never a visual scan.
for rule in $STANDING_RULES; do
  dst="$RULES_DIR/$rule.md"
  [ -L "$dst" ] || continue                      # reported above
  if [ ! -r "$dst" ]; then
    echo "error: link does not resolve: $dst -> $(readlink "$dst")" >&2
    problems=$((problems + 1))
  elif [ "$(head -n 1 "$dst" | tr -d '\r')" != "$(rule_heading "$rule")" ]; then
    echo "error: $dst -> $(readlink "$dst") does not open with '$(rule_heading "$rule")'" >&2
    problems=$((problems + 1))
  fi
done

echo "synced $RULES_DIR (standing rules via $PREFIX/): ${created} linked, ${current} already current, ${removed} stale removed"

if [ "$problems" -gt 0 ]; then
  echo "FAILED: ${problems} standing-rule link problem(s) — see errors above" >&2
  exit 1
fi
exit 0
