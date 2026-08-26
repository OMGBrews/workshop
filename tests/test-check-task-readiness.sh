#!/usr/bin/env bash
# Regression tests for task-finalize/check-task-readiness.sh.  Each readiness
# rule is broken independently from a committed, ready fixture so the check
# cannot go green merely because some unrelated prerequisite was absent.

set -euo pipefail

DEVTOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$DEVTOOLS_ROOT/.agents/skills/task-finalize/check-task-readiness.sh"
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
        "$repo/docs/work/tasks/later" "$repo/docs/work/tasks/never"
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
expect_readiness "rule-8-invalid-finalized-at" 1 invalid_finalized_at \
    "FAIL 8" "does not name a commit"
expect_readiness "done-only-criterion" 0 done_only_criterion "PASS 2"
expect_readiness "tilde-only-criterion" 0 tilde_only_criterion "PASS 2"
expect_readiness "block-dependencies" 0 block_dependencies "PASS 7"
expect_readiness "unmatched-dependency-warning" 0 unmatched_dependency \
    "PASS 7" "WARN 7 dependency 'not-current' matches no current task file"

# The default interface must not silently choose a task, and an on-disk brief
# outside a repository must not borrow the devtools worktree that holds this
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

if [ "$failures" -ne 0 ]; then
    echo "$failures check-task-readiness assertion(s) failed" >&2
    exit 1
fi
echo "all check-task-readiness assertions passed"
