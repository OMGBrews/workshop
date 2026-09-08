#!/usr/bin/env bash
# Exercise the history baseline with real Git histories and local-only remotes.
# Fresh transport clones prove rewritten session commits are actually absent.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$WORKSHOP_ROOT/.agents/skills/task-finalize/task-history-baseline.sh"
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0 GIT_AUTHOR_NAME='History test'
export GIT_AUTHOR_EMAIL='history@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_AUTHOR_DATE='2001-01-01T00:00:00Z'
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"

failures=0
assertions=0
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }
assert_equal() {
    assertions=$((assertions + 1))
    if [ "$2" != "$3" ]; then
        fail "$1: expected '$3', got '$2'"
    fi
}
field() { printf '%s\n' "$OUTPUT" | sed -n "s/^$1=//p"; }
invoke() {
    RC=0
    OUTPUT="$(bash "$HELPER" "$@" 2>&1)" || RC=$?
    assertions=$((assertions + 1))
    if [ -z "$(field REASON)" ]; then
        fail "helper omitted explanation: $* (exit $RC): $OUTPUT"
    fi
}
expect_check() { # label, expected status, repo, inspected commit, stamp
    local label="$1" expected="$2"
    shift 2
    invoke check "$@"
    assert_equal "$label status" "$(field STATUS)" "$expected"
    case "$expected" in
        usable | reverify) assert_equal "$label exit" "$RC" 0 ;;
        malformed) assert_equal "$label exit" "$RC" 1 ;;
        error) assert_equal "$label exit" "$RC" 2 ;;
    esac
}
commit_file() { # repo, filename, content, message
    printf '%s\n' "$3" > "$1/$2"
    git -C "$1" add -- "$2"
    git -C "$1" commit -qm "$4"
}
make_remote() { # fixture name; exports REPO, REMOTE, BASE
    REPO="$FIXTURES/$1-work"
    REMOTE="$FIXTURES/$1.git"
    git init -q --bare --initial-branch=trunk "$REMOTE"
    git init -q --initial-branch=trunk "$REPO"
    commit_file "$REPO" README.md baseline 'shared baseline'
    BASE="$(git -C "$REPO" rev-parse HEAD)"
    git -C "$REPO" remote add origin "file://$REMOTE"
    git -C "$REPO" push -q -u origin trunk
    git -C "$REPO" remote set-head origin -a >/dev/null
}
select_conservative() { # label, repo, inspected commit, expected baseline
    invoke select "$2" "$3"
    assert_equal "$1 selection exit" "$RC" 0
    assert_equal "$1 durability" "$(field DURABILITY)" conservative
    assert_equal "$1 baseline" "$(field BASELINE)" "$4"
}
select_limited() { # label, repo, inspected commit
    invoke select "$2" "$3"
    assert_equal "$1 selection exit" "$RC" 0
    assert_equal "$1 durability" "$(field DURABILITY)" limited
    assert_equal "$1 preserves inspected commit" "$(field BASELINE)" "$3"
}

make_remote basic
commit_file "$REPO" tracked.txt first 'tracked change'
INSPECTED="$(git -C "$REPO" rev-parse HEAD)"
expect_check ancestor usable "$REPO" "$INSPECTED" "$BASE"
expect_check same-commit usable "$REPO" "$INSPECTED" "$INSPECTED"
expect_check missing-object reverify "$REPO" "$INSPECTED" 1111111111111111111111111111111111111111
expect_check malformed-marker malformed "$REPO" "$INSPECTED" not-a-commit
BLOB="$(git -C "$REPO" rev-parse HEAD:tracked.txt)"
expect_check noncommit-object reverify "$REPO" "$INSPECTED" "$BLOB"
git -C "$REPO" checkout -qb sibling "$BASE"
commit_file "$REPO" sibling.txt sibling 'unmerged sibling'
SIBLING="$(git -C "$REPO" rev-parse HEAD)"
expect_check existing-nonancestor reverify "$REPO" "$INSPECTED" "$SIBLING"
expect_check missing-inspected error "$REPO" 2222222222222222222222222222222222222222 "$BASE"
RC=0
OUTPUT="$(bash "$HELPER" check "$FIXTURES/nonexistent" "$INSPECTED" "$BASE" 2>&1)" || RC=$?
assert_equal 'missing repository exit' "$RC" 2
assertions=$((assertions + 1))
if [ -z "$OUTPUT" ]; then fail 'missing repository omitted diagnostic'; fi
select_conservative non-main-default "$REPO" "$INSPECTED" "$BASE"

# Without a trustworthy remote, preserve the exact inspected SHA and disclose
# its limited durability. Never substitute whichever checkout HEAD is current.
git -C "$REPO" remote remove origin
select_limited no-remote "$REPO" "$INSPECTED"

make_remote unavailable
commit_file "$REPO" feature.txt change 'unpublished work'
INSPECTED="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" remote set-url origin "file://$FIXTURES/does-not-exist.git"
select_limited fetch-unavailable "$REPO" "$INSPECTED"

# Selection must refresh the remote, even when a plausible but older
# origin/trunk and origin/HEAD already exist in the inspecting clone.
make_remote refresh
git clone -q "file://$REMOTE" "$FIXTURES/refresh-publisher"
commit_file "$FIXTURES/refresh-publisher" upstream.txt update 'published advance'
UPDATED="$(git -C "$FIXTURES/refresh-publisher" rev-parse HEAD)"
git -C "$FIXTURES/refresh-publisher" push -q origin trunk
git -C "$REPO" fetch -q "file://$REMOTE" trunk
git -C "$REPO" merge -q --ff-only FETCH_HEAD
assert_equal 'fixture retains stale tracking ref' "$(git -C "$REPO" rev-parse origin/trunk)" "$BASE"
commit_file "$REPO" feature.txt feature 'local feature'
INSPECTED="$(git -C "$REPO" rev-parse HEAD)"
select_conservative refreshed-default "$REPO" "$INSPECTED" "$UPDATED"

git clone -q --depth=1 "file://$REMOTE" "$FIXTURES/shallow"
SHALLOW_HEAD="$(git -C "$FIXTURES/shallow" rev-parse HEAD)"
assert_equal 'fixture is shallow' "$(git -C "$FIXTURES/shallow" rev-parse --is-shallow-repository)" true
expect_check shallow-present-marker reverify "$FIXTURES/shallow" "$SHALLOW_HEAD" "$SHALLOW_HEAD"
expect_check shallow-missing-marker reverify "$FIXTURES/shallow" "$SHALLOW_HEAD" "$BASE"

for rewrite in squash rebase amend; do
    make_remote "$rewrite"
    git -C "$REPO" checkout -qb topic
    commit_file "$REPO" feature.txt 'verified feature' "feature before $rewrite"
    VERIFIED="$(git -C "$REPO" rev-parse HEAD)"
    select_conservative "$rewrite before rewrite" "$REPO" "$VERIFIED" "$BASE"
    SELECTED="$(field BASELINE)"
    commit_file "$REPO" task.txt "$SELECTED" 'record verification baseline'
    case "$rewrite" in
        squash)
            git -C "$REPO" checkout -q trunk
            git -C "$REPO" merge -q --squash topic
            git -C "$REPO" commit -qm 'squashed feature and brief'
            ;;
        rebase)
            git -C "$REPO" checkout -q trunk
            commit_file "$REPO" upstream.txt advance 'default branch advances'
            git -C "$REPO" push -q origin trunk
            git -C "$REPO" checkout -q topic
            git -C "$REPO" rebase trunk
            git -C "$REPO" checkout -q trunk
            git -C "$REPO" merge -q --ff-only topic
            ;;
        amend)
            # Rewind only this disposable fixture's topic to the verified
            # commit, retaining the task in the index, then replace that commit.
            git -C "$REPO" reset --soft "$VERIFIED"
            git -C "$REPO" commit -q --amend -m 'amended feature with brief'
            git -C "$REPO" checkout -q trunk
            git -C "$REPO" merge -q --ff-only topic
            ;;
    esac
    git -C "$REPO" push -q origin trunk
    FRESH="$FIXTURES/$rewrite-fresh"
    git clone -q "file://$REMOTE" "$FRESH"
    LANDED="$(git -C "$FRESH" rev-parse HEAD)"
    assert_equal "$rewrite carries original baseline" "$(git -C "$FRESH" show HEAD:task.txt)" "$SELECTED"
    assertions=$((assertions + 1))
    if git -C "$FRESH" cat-file -e "$VERIFIED^{commit}" 2>/dev/null; then
        fail "$rewrite fixture still contains old verified commit"
    fi
    expect_check "$rewrite legacy marker" reverify "$FRESH" "$LANDED" "$VERIFIED"
    expect_check "$rewrite durable marker" usable "$FRESH" "$LANDED" "$SELECTED"
    HISTORY="$(git -C "$FRESH" log --format=%H "$SELECTED..$LANDED" -- feature.txt)"
    assertions=$((assertions + 1))
    if [ -z "$HISTORY" ]; then
        fail "$rewrite history window omitted rewritten feature"
    fi
    assert_equal "$rewrite scoped diff includes feature" \
        "$(git -C "$FRESH" diff --name-only "$SELECTED" "$LANDED" -- feature.txt)" feature.txt
done

if [ "$failures" -ne 0 ]; then
    printf '%s of %s history baseline assertions failed\n' "$failures" "$assertions" >&2
    exit 1
fi
printf '%s history baseline assertions passed\n' "$assertions"
