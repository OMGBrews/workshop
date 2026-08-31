#!/usr/bin/env bash
#
# migrate-task-format.sh — one-time conversion of a repo's task documents from
# the legacy bold-metadata format to the canonical frontmatter format.
#
# Legacy format (pre-2026-07 convergence):        Canonical format:
#   (either bold spelling — `**Status**: X` or `**Status:** X`)
#   **Created**: 2026-07-14                         ---
#   **Status**: Not Started                         status: not-started
#   **Effort**: Small                               effort: small
#   ---                                             priority: medium
#   ## Requirements                                 dependencies: []
#   ## Verification                                 ---
#                                                   ## Acceptance criteria (+ AC sentinels)
#                                                   ## Stopping conditions
#
# The Created line is dropped deliberately: creation dates are derived from
# `git log --diff-filter=A --follow` — a recorded date goes stale, git's does not.
#
# Usage:
#   migrate-task-format.sh [REPO_ROOT]     (default: cwd)
#
# Idempotent: files that already carry YAML frontmatter AND the AC sentinels
# are skipped. Mid-vintage briefs (frontmatter, no AC sentinels) get their existing
# checklist section wrapped in AC sentinels; a brief with no checklist at all
# is reported and the script exits non-zero — its acceptance criteria must be
# hand-written in the same change. Files whose Status/Effort can't be parsed
# are left untouched and reported; the script then exits non-zero.

set -euo pipefail

REPO_ROOT="${1:-$PWD}"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }

# ---- locate the tasks root -------------------------------------------
TASKS_REL="docs/work/tasks"
if [[ ! -d "$REPO_ROOT/$TASKS_REL" ]]; then
  err "no tasks directory ($TASKS_REL) under $REPO_ROOT"
fi
TASKS_DIR="$REPO_ROOT/$TASKS_REL"

# ---- convert task files ----------------------------------------------
migrated=0 wrapped=0 skipped=0 failed=0

for f in "$TASKS_DIR"/{now,soon,later,never}/*.md; do
  [[ -e "$f" ]] || continue
  base="$(basename "$f")"
  [[ "$base" == "README.md" || "$base" == "_TEMPLATE.md" ]] && continue
  rel="$TASKS_REL/${f#"$TASKS_DIR/"}"

  if [[ "$(head -1 "$f")" == "---" ]]; then
    # Frontmatter present: this is a converged-format or mid-vintage brief.
    # Conformant briefs already carry the AC sentinels; a mid-vintage brief
    # has the checklist but not the sentinels, and one with no checklist at
    # all is reported and fails the run (its acceptance criteria must be
    # hand-written in the same change).
    if grep -q '^<!-- AC:BEGIN' "$f"; then
      echo "skip    $rel (frontmatter + AC sentinels present)"
      skipped=$((skipped + 1))
      continue
    fi
    if grep -q '^- \[[ x~]\]' "$f"; then
      tmp="$(mktemp)"
      awk -v marker='<!-- AC:BEGIN — DO NOT REMOVE: /task-finalize, /task-move, and the task-queue worker parse the AC list between these sentinels. -->' '
        # Wrap the checklist section in AC sentinels: BEGIN right after the
        # heading that precedes the first checklist item, END before the next
        # heading (or at EOF).
        /^## / {
          if (first_item && !end_line) end_line = NR
          if (!first_item) last_h = NR
        }
        /^- \[[ x~]\]/ && !first_item { first_item = NR }
        { line[NR] = $0 }
        END {
          if (!first_item) exit 1
          if (!end_line) end_line = NR + 1
          for (i = 1; i <= NR + 1; i++) {
            if (i == last_h + 1) print marker
            if (i == end_line) { print "<!-- AC:END -->"; print "" }
            if (i <= NR) print line[i]
          }
        }
      ' "$f" | cat -s > "$tmp"   # squeeze blank lines, as the legacy path does
      if [[ -s "$tmp" ]]; then
        mv "$tmp" "$f"
        echo "wrap    $rel (mid-vintage: AC sentinels added around the existing checklist)"
        wrapped=$((wrapped + 1))
      else
        rm -f "$tmp"
        echo "FAIL    $rel — checklist found but sentinel wrapping produced nothing" >&2
        failed=$((failed + 1))
      fi
      continue
    else
      echo "FAIL    $rel — frontmatter present but no checklist (- [ ]) to wrap in AC sentinels; write acceptance criteria by hand" >&2
      failed=$((failed + 1))
      continue
    fi
  fi

  # Both bold-delimiter spellings occur in the wild: `**Status**: X` and
  # `**Status:** X`. captains-log/cms wrote the second in 16 of 22 files.
  status_raw="$(grep -m1 -E '^\*\*Status(\*\*:|:\*\*)' "$f" | sed -E 's/^\*\*Status(\*\*:|:\*\*)[[:space:]]*//' || true)"
  effort_raw="$(grep -m1 -E '^\*\*Effort(\*\*:|:\*\*)' "$f" | sed -E 's/^\*\*Effort(\*\*:|:\*\*)[[:space:]]*//' || true)"

  case "$status_raw" in
    "Not Started") status="not-started" ;;
    "In Progress") status="in-progress" ;;
    "Blocked")     status="blocked" ;;
    *) echo "FAIL    $rel — unparseable **Status**: '${status_raw}'" >&2
       failed=$((failed + 1)); continue ;;
  esac
  case "$effort_raw" in
    Small)  effort="small" ;;
    Medium) effort="medium" ;;
    Large)  effort="large" ;;
    *) echo "FAIL    $rel — unparseable **Effort**: '${effort_raw}'" >&2
       failed=$((failed + 1)); continue ;;
  esac

  tmp="$(mktemp)"
  {
    printf -- '---\nstatus: %s\neffort: %s\npriority: medium\ndependencies: []\n---\n' \
      "$status" "$effort"
    awk '
      # Drop the legacy metadata lines and the standalone --- separator that
      # immediately follows them (within 2 lines of the last metadata line).
      /^\*\*(Created|Status|Effort)(\*\*:|:\*\*)/ { expect_hr = 2; next }
      /^---$/ && expect_hr > 0 { expect_hr = 0; next }
      { if (expect_hr > 0) expect_hr-- }

      # Requirements -> Acceptance criteria, wrapped in AC sentinels.
      /^## Requirements$/ {
        print "## Acceptance criteria"
        print "<!-- AC:BEGIN — DO NOT REMOVE: /task-finalize, /task-move, and the task-queue worker parse the AC list between these sentinels. -->"
        in_ac = 1
        next
      }
      /^## / && in_ac {
        print "<!-- AC:END -->"
        print ""
        in_ac = 0
      }

      # Verification -> Stopping conditions.
      /^## Verification$/ { print "## Stopping conditions"; next }

      { print }

      END { if (in_ac) print "<!-- AC:END -->" }
    ' "$f" | cat -s   # squeeze the doubled blank lines the metadata removal leaves
  } > "$tmp"
  mv "$tmp" "$f"
  echo "migrate $rel (status=$status effort=$effort)"
  migrated=$((migrated + 1))
done

echo
echo "migrated $migrated, wrapped $wrapped, skipped $skipped, failed $failed"
[[ "$failed" -eq 0 ]] || exit 1
