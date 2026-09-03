#!/usr/bin/env bash
# Tests for Tools/migrate-task-format.sh.
#
# The script's contract, asserted here:
#   1. converts a legacy task to frontmatter, dropping the Created line and
#      wrapping Requirements in the AC sentinels;
#   2. accepts BOTH bold spellings of the metadata lines — `**Status**: X` and
#      `**Status:** X`. captains-log/cms wrote the second in 16 of 22 files, and
#      the script refused all 16 until 2026-07-26;
#   3. is idempotent — a file that already has frontmatter is skipped;
#   4. refuses a file whose Status it cannot parse, leaves it untouched, and
#      exits non-zero (a silent pass here would migrate a repo "successfully"
#      while leaving documents the task skills cannot read).
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE="$WORKSHOP_ROOT/Tools/migrate-task-format.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Fixture: a repo with a tasks dir the script converts under.
new_repo() { # <name> -> prints repo root
  local root="$TMP/$1"
  mkdir -p "$root/docs/work/tasks/now"
  printf '%s\n' "$root"
}

legacy_task() { # <file> <status-line>
  cat > "$1" <<EOF
# A legacy task

$2
**Effort**: Medium

---

## Goal

Do the thing.

## Requirements

- [ ] First outcome
- [ ] Second outcome

## Verification

The thing is done.
EOF
}

# --- 1. classic spelling: **Status**: --------------------------------------
R="$(new_repo classic)"
legacy_task "$R/docs/work/tasks/now/a.md" '**Created**: 2026-01-01
**Status**: Not Started'
out="$(bash "$MIGRATE" "$R" 2>&1)" || fail "migrate failed on the classic spelling: $out"
head -1 "$R/docs/work/tasks/now/a.md" | grep -qx -- '---' || fail "no frontmatter written"
grep -qx 'status: not-started' "$R/docs/work/tasks/now/a.md" || fail "status not written"
grep -qx 'effort: medium' "$R/docs/work/tasks/now/a.md" || fail "effort not written"
grep -q 'AC:BEGIN' "$R/docs/work/tasks/now/a.md" || fail "AC sentinels not written"
grep -q 'AC:END' "$R/docs/work/tasks/now/a.md" || fail "AC:END not written"
grep -qx '## Stopping conditions' "$R/docs/work/tasks/now/a.md" || fail "Verification not renamed"
grep -q '^\*\*Created' "$R/docs/work/tasks/now/a.md" && fail "Created line survived"
echo "ok 1 - converts the classic **Status**: spelling"

# --- 2. colon-inside-bold spelling: **Status:** ----------------------------
# The regression this file exists for. Before the fix the script reported
# "unparseable **Status**: ''" and left the file alone — so a repo written in
# this dialect migrated 0 of its tasks while the run still looked orderly.
R="$(new_repo inner_colon)"
legacy_task "$R/docs/work/tasks/now/b.md" '**Created:** 2026-01-01
**Status:** In Progress'
out="$(bash "$MIGRATE" "$R" 2>&1)" || fail "migrate failed on the **Status:** spelling: $out"
grep -qx 'status: in-progress' "$R/docs/work/tasks/now/b.md" \
  || fail "**Status:** spelling not parsed; file reads: $(head -6 "$R/docs/work/tasks/now/b.md")"
grep -q '^\*\*Created' "$R/docs/work/tasks/now/b.md" && fail "**Created:** line survived"
echo "ok 2 - converts the **Status:** spelling"

# --- 3. idempotent ----------------------------------------------------------
out="$(bash "$MIGRATE" "$R" 2>&1)" || fail "second run failed: $out"
echo "$out" | grep -q 'skipped 1' || fail "second run did not skip the migrated file: $out"
echo "$out" | grep -q 'migrated 0' || fail "second run re-migrated: $out"
echo "ok 3 - idempotent"

# --- 4. unparseable status is refused, loudly and non-destructively ---------
R="$(new_repo bad_status)"
legacy_task "$R/docs/work/tasks/now/c.md" '**Status**: Done'
before="$(cat "$R/docs/work/tasks/now/c.md")"
set +e
out="$(bash "$MIGRATE" "$R" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "exited 0 despite an unparseable status — a caller cannot tell"
echo "$out" | grep -q "unparseable" || fail "did not name the offending file: $out"
echo "$out" | grep -q 'failed 1' || fail "did not count the failure: $out"
[ "$(cat "$R/docs/work/tasks/now/c.md")" = "$before" ] || fail "refused file was modified anyway"
echo "ok 4 - refuses an unparseable status, leaves the file untouched, exits non-zero"
