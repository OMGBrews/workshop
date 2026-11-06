#!/usr/bin/env bash
# Regression tests for task-finalize/check-task-readiness.sh.  Each readiness
# rule is broken independently from a committed, ready fixture so the check
# cannot go green merely because some unrelated prerequisite was absent.

set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$WORKSHOP_ROOT/.agents/skills/task-finalize/check-task-readiness.sh"
TASK_REL="docs/work/tasks/now/good-task.md"

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git_init() {
    git init -q "$1"
    git -C "$1" config user.email check@test
    git -C "$1" config user.name check
}

write_good_brief() { # <repo> <dependencies line(s)>
    local repo="$1" dependencies="$2" sha
    sha="$(git -C "$repo" rev-parse HEAD)"
    cat >"$repo/$TASK_REL" <<EOF
---
status: not-started
effort: small
priority: medium
dependencies: $dependencies
finalized-at: $sha
---

# Good task

**In brief**: A fixture that can be finalized or parked.

## Goal

Ship a real outcome.

## Acceptance criteria
<!-- AC:BEGIN -->

- [ ] The brief is ready.

<!-- AC:END -->

## Stopping conditions

The focused regression test exits zero.
EOF
}

make_good_repo() { # <repo>
    local repo="$1"
    git_init "$repo"
    mkdir -p "$repo/docs/work/tasks/now" "$repo/docs/work/tasks/soon" \
        "$repo/docs/work/tasks/later" "$repo/docs/work/tasks/parked"
    printf 'fixture baseline\n' >"$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -qm 'fixture: readiness baseline'
    write_good_brief "$repo" '[]'
}

run_checker() {
    CHECK_OUTPUT=""
    CHECK_RC=0
    CHECK_OUTPUT="$(bash "$CHECKER" "$@" 2>&1)" || CHECK_RC=$?
}

assert_contains() { # <label> <needle>
    if [[ "$CHECK_OUTPUT" != *"$2"* ]]; then
        fail "$1: output lacks '$2'"
        printf '%s\n' "$CHECK_OUTPUT" | sed 's/^/    /'
    fi
}

expect_readiness() { # <label> <exit> <mutation-function> <expected-output>...
    local label="$1" wanted_rc="$2" mutate="$3" expected repo
    shift 3
    repo="$TMP/$label"
    make_good_repo "$repo"
    "$mutate" "$repo"
    run_checker "$repo/$TASK_REL"
    if [ "$CHECK_RC" -ne "$wanted_rc" ]; then
        fail "$label: exit $CHECK_RC, wanted $wanted_rc"
        printf '%s\n' "$CHECK_OUTPUT" | sed 's/^/    /'
        return
    fi
    for expected in "$@"; do
        assert_contains "$label" "$expected"
    done
    echo "ok: $label"
}

no_change() { :; }
empty_goal() { sed -i 's/^Ship a real outcome\.$/<!-- placeholder -->/' "$1/$TASK_REL"; }
missing_begin() { sed -i '/^<!-- AC:BEGIN -->$/d' "$1/$TASK_REL"; }
unanchored_begin() {
    sed -i 's/^<!-- AC:BEGIN -->$/Prose may mention <!-- AC:BEGIN --> here./' "$1/$TASK_REL"
}
misordered_sentinels() {
    sed -i '/^<!-- AC:BEGIN -->$/d; /^<!-- AC:END -->$/d' "$1/$TASK_REL"
    sed -i '/^## Acceptance criteria$/a <!-- AC:END -->' "$1/$TASK_REL"
    printf '\n<!-- AC:BEGIN -->\n' >>"$1/$TASK_REL"
}
empty_stopping() {
    sed -i 's/^The focused regression test exits zero\.$/<!-- placeholder -->/' "$1/$TASK_REL"
}
invalid_status() { sed -i 's/^status: not-started$/status: done/' "$1/$TASK_REL"; }
invalid_effort() { sed -i 's/^effort: small$/effort: enormous/' "$1/$TASK_REL"; }
open_question() { printf '\n## Open questions\n\nWhich API should own this?\n' >>"$1/$TASK_REL"; }
invalid_priority() { sed -i 's/^priority: medium$/priority: urgent/' "$1/$TASK_REL"; }
invalid_dependency() { sed -i 's/^dependencies: \[\]$/dependencies: [not_a_slug]/' "$1/$TASK_REL"; }
invalid_finalized_at() {
    sed -i 's/^finalized-at: .*/finalized-at: 0123456789abcdef0123456789abcdef01234567/' "$1/$TASK_REL"
}
malformed_finalized_at() { sed -i 's/^finalized-at: .*/finalized-at: not-a-sha/' "$1/$TASK_REL"; }
duplicate_finalized_at() {
    sed -i '/^finalized-at:/p' "$1/$TASK_REL"
}
tilde_only_criterion() {
    sed -i 's/^- \[ \] The brief is ready\.$/- [~] The brief is in progress./' "$1/$TASK_REL"
}
done_only_criterion() {
    sed -i 's/^- \[ \] The brief is ready\.$/- [x] The brief is complete./' "$1/$TASK_REL"
}
block_dependencies() {
    sed -i 's/^dependencies: \[\]$/dependencies:\n  - known-dependency/' "$1/$TASK_REL"
    : >"$1/docs/work/tasks/now/known-dependency.md"
}
unmatched_dependency() {
    sed -i 's/^dependencies: \[\]$/dependencies: [not-current]/' "$1/$TASK_REL"
}
remove_finalized_at() { sed -i '/^finalized-at:/d' "$1/$TASK_REL"; }

# Good first: every numbered rule has to report a positive verdict before the
# mutation cases below can prove their own rule rather than a broken baseline.
expect_readiness "good" 0 no_change \
    "PASS 1" "PASS 2" "PASS 3" "PASS 4" "PASS 5" "PASS 6" "PASS 7" "PASS 8"

expect_readiness "rule-1-empty-goal" 1 empty_goal "FAIL 1" "PASS 2"
expect_readiness "rule-2-missing-begin" 1 missing_begin "FAIL 2" "PASS 3"
expect_readiness "rule-2-unanchored-begin" 1 unanchored_begin "FAIL 2" "missing AC:BEGIN"
expect_readiness "rule-2-misordered-sentinels" 1 misordered_sentinels \
    "FAIL 2" "misordered or repeated"
expect_readiness "rule-3-empty-stopping" 1 empty_stopping "FAIL 3" "PASS 4"
expect_readiness "rule-4-invalid-status" 1 invalid_status "FAIL 4" "status: done is rejected"
expect_readiness "rule-5-invalid-effort" 1 invalid_effort "FAIL 5" "effort: invalid value"
expect_readiness "rule-6-open-questions" 1 open_question "FAIL 6" "Open questions still contain"
expect_readiness "rule-7-invalid-priority" 1 invalid_priority "FAIL 7" "priority: invalid value"
expect_readiness "rule-7-invalid-dependency" 1 invalid_dependency \
    "FAIL 7" "invalid task slug"
expect_readiness "rule-8-unavailable-finalized-at" 0 invalid_finalized_at \
    "PASS 8" "WARN 8" "full re-verification required"
expect_readiness "rule-8-malformed-finalized-at" 1 malformed_finalized_at \
    "FAIL 8" "not a 40-hex commit SHA"
expect_readiness "rule-8-duplicate-finalized-at" 1 duplicate_finalized_at \
    "FAIL 8" "appears 2 times"
expect_readiness "done-only-criterion" 0 done_only_criterion "PASS 2"
expect_readiness "tilde-only-criterion" 0 tilde_only_criterion "PASS 2"
expect_readiness "block-dependencies" 0 block_dependencies "PASS 7"
expect_readiness "unmatched-dependency-warning" 0 unmatched_dependency \
    "PASS 7" "WARN 7 dependency 'not-current' matches no current task file"

# The default interface must not silently choose a task, and an on-disk brief
# outside a repository must not borrow the Workshop worktree that holds this
# bundled script.
run_checker
[ "$CHECK_RC" -eq 2 ] || fail "missing task argument: exit $CHECK_RC, wanted 2"
assert_contains "missing task argument" "usage:"
run_checker "$TMP/does-not-exist.md"
[ "$CHECK_RC" -eq 2 ] || fail "missing task file: exit $CHECK_RC, wanted 2"
assert_contains "missing task file" "is not a regular file"
printf '# plain task\n' >"$TMP/plain.md"
run_checker "$TMP/plain.md"
[ "$CHECK_RC" -eq 2 ] || fail "non-repository task file: exit $CHECK_RC, wanted 2"
assert_contains "non-repository task file" "not inside a Git worktree"

# Conformance mode shares only the document-format parser.  A human draft is
# valid before finalization; the same brief in finalized/ must have a real stamp.
repo="$TMP/conformance-policy"
make_good_repo "$repo"
remove_finalized_at "$repo"
run_checker --conformance "$repo/$TASK_REL" human
[ "$CHECK_RC" -eq 0 ] || fail "human conformance draft: exit $CHECK_RC, wanted 0"
run_checker --conformance "$repo/$TASK_REL" finalized
[ "$CHECK_RC" -eq 1 ] || fail "finalized conformance stamp policy: exit $CHECK_RC, wanted 1"
assert_contains "finalized conformance stamp policy" "missing finalized-at"

# Parking is a path-specific contract shared by readiness and conformance.
# Begin with a fully ready note, then break one property at a time; every bad
# case must fail in both interfaces for the parking diagnostic itself.
write_parking_note() {
    sed -i '/^## Goal$/i ## Parked\n\n**Why**: Capacity is reserved for the current release.\n\n**Unpark when**: The current release has landed.\n' "$1"
}
parking_missing() { sed -i '/^## Parked$/,/^## Goal$/{ /^## Goal$/!d; }' "$1"; }
parking_missing_why() { sed -i '/^\*\*Why\*\*:/d' "$1"; }
parking_missing_unpark() { sed -i '/^\*\*Unpark when\*\*:/d' "$1"; }
parking_empty_why() { sed -i 's/^\*\*Why\*\*:.*/**Why**:/' "$1"; }
parking_comment_only() {
    sed -i 's/^\*\*Unpark when\*\*:.*/**Unpark when**: <!-- explain\nwhen to resume -->/' "$1"
}
parking_placeholder() { sed -i 's/^\*\*Why\*\*:.*/**Why**: <why the work was set aside>/' "$1"; }
parking_tbd() { sed -i 's/^\*\*Unpark when\*\*:.*/**Unpark when**: TBD/' "$1"; }
parking_date_only() {
    parking_missing "$1"
    sed -i '/^dependencies:/a unpark-after: 2030-01-01' "$1"
}
parking_misplaced() {
    parking_missing "$1"
    printf '\n## Parked\n\n**Why**: Capacity is reserved.\n\n**Unpark when**: The release lands.\n' >>"$1"
}
parking_duplicate() {
    printf '\n## Parked\n\n**Why**: Another reason.\n\n**Unpark when**: Another condition.\n' >>"$1"
}
parking_multiline() {
    sed -i 's/^\*\*Why\*\*:.*/**Why**:\nCapacity is reserved for\nthe current release./; s/^\*\*Unpark when\*\*:.*/**Unpark when**:\nThe current release\nhas landed./' "$1"
}

expect_parking() { # <label> <exit> <mutation>
    local label="$1" wanted_rc="$2" mutate="$3" repo file interface
    repo="$TMP/parking-$label"
    make_good_repo "$repo"
    file="$repo/docs/work/tasks/parked/good-task.md"
    mv "$repo/$TASK_REL" "$file"
    write_parking_note "$file"
    "$mutate" "$file"
    for interface in readiness conformance; do
        if [ "$interface" = readiness ]; then run_checker "$file"
        else run_checker --conformance "$file" human
        fi
        if [ "$CHECK_RC" -ne "$wanted_rc" ]; then
            fail "parking $label ($interface): exit $CHECK_RC, wanted $wanted_rc"
            printf '%s\n' "$CHECK_OUTPUT" | sed 's/^/    /'
        fi
        if [ "$wanted_rc" -eq 1 ]; then
            assert_contains "parking $label ($interface)" "parking note"
        fi
    done
    echo "ok: parking $label in readiness and conformance"
}
# A documented example must not substitute for the actual note. Shorter or
# mismatched delimiters inside a fence do not close its Markdown code block.
parking_fenced_example() {
    parking_missing "$1"
    # shellcheck disable=SC2016 # Backticks are literal Markdown fence fixtures.
    sed -i '/^## Goal$/i ````\n```\n~~~\n## Parked\n\n**Why**: Example reason.\n\n**Unpark when**: Example condition.\n````\n' "$1"
}
parking_indented_example() {
    parking_missing "$1"
    sed -i '/^## Goal$/i \    ## Parked\n\n    **Why**: Example reason.\n\n    **Unpark when**: Example condition.\n' "$1"
}
expect_parking fenced-example 1 parking_fenced_example
expect_parking indented-example 1 parking_indented_example
parking_with_issues() {
    sed -i '/^## Parked$/i **Issues**: [#17](https://github.com/example/project/issues/17) Deferred improvement\n' "$1"
}
parking_with_intervening_prose() {
    sed -i '/^## Parked$/i Unrelated introductory prose.\n' "$1"
}
parking_with_duplicate_issues() {
    parking_with_issues "$1"
    parking_with_issues "$1"
}
expect_parking valid 0 no_change
expect_parking with-issues 0 parking_with_issues
expect_parking intervening-prose 1 parking_with_intervening_prose
expect_parking duplicate-issues 1 parking_with_duplicate_issues
expect_parking multiline 0 parking_multiline
expect_parking missing 1 parking_missing
expect_parking missing-why 1 parking_missing_why
expect_parking missing-unpark 1 parking_missing_unpark
expect_parking empty-why 1 parking_empty_why
expect_parking comment-only 1 parking_comment_only
expect_parking placeholder 1 parking_placeholder
expect_parking tbd 1 parking_tbd
expect_parking date-only 1 parking_date_only
expect_parking misplaced 1 parking_misplaced
expect_parking duplicate 1 parking_duplicate

# A valid parked draft can remain unfinalized and retain design questions.
# Readiness must still reject those independent handoff requirements.
repo="$TMP/parked-human-draft"
make_good_repo "$repo"
remove_finalized_at "$repo"
open_question "$repo"
file="$repo/docs/work/tasks/parked/good-task.md"
mv "$repo/$TASK_REL" "$file"
write_parking_note "$file"
run_checker --conformance "$file" human
[ "$CHECK_RC" -eq 0 ] || fail "parked human draft: exit $CHECK_RC, wanted 0"
run_checker "$file"
[ "$CHECK_RC" -eq 1 ] || fail "parked draft readiness: exit $CHECK_RC, wanted 1"
assert_contains "parked draft readiness" "FAIL 6"
assert_contains "parked draft readiness" "FAIL 8"

# Neither another task bucket nor a problem parked bucket inherits this rule.
# The ordinary ready fixture above already proves a note-less now/ brief passes.
repo="$TMP/parking-path-scope"
make_good_repo "$repo"
mkdir -p "$repo/docs/work/problems/parked"
cp "$repo/$TASK_REL" "$repo/docs/work/problems/parked/good-task.md"
run_checker "$repo/docs/work/problems/parked/good-task.md"
[ "$CHECK_RC" -eq 0 ] || fail "problem parked path: exit $CHECK_RC, wanted 0"
run_checker --conformance "$repo/$TASK_REL" human
[ "$CHECK_RC" -eq 0 ] || fail "ordinary note-less task conformance: exit $CHECK_RC, wanted 0"

if [ "$failures" -ne 0 ]; then
    echo "$failures check-task-readiness assertion(s) failed" >&2
    exit 1
fi
echo "all check-task-readiness assertions passed"
