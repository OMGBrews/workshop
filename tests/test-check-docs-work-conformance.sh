#!/usr/bin/env bash
# Tests for Tools/check-docs-work-conformance.sh — the per-repo check that
# audits a repo's docs/work/ against the fleet docs work-directory contract.
#
# The headline case is the unmigrated baseline: a repo whose tasks still sit
# at the legacy docs/tasks/ root. A conformance script that goes green there
# would tell every repo it has nothing to do, so that fixture is asserted red
# first, then a complete target fixture is asserted green, and every further
# case mutates ONE property of the conformant fixture and asserts that the
# clause owning it is the one that fires, by number. Asserting the identifying
# output text as well as the coarse exit class keeps a wrong-but-nonzero exit
# (every mutation failing for one unrelated reason) from reading as coverage.
#
# Every fixture is a real Git repository: the checker's explicit precondition
# is a Git worktree root, and the handoff clause depends on tracked-file
# identity, so fixtures that were not repositories would exercise a different
# script than the one that ships.
#
# shellcheck disable=SC2016  # $vars and backticks below are fixture text or
#                              awk programs, not shell expansions.
set -euo pipefail

DEVTOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DEVTOOLS_ROOT/Tools/check-docs-work-conformance.sh"

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git_init() {
    git init -q "$1"
    git -C "$1" config user.email check@test
    git -C "$1" config user.name check
}

# A valid ordinary brief: the four author-required frontmatter fields and the
# AC sentinels. $3 = extra frontmatter lines to inject before the closing ---
# (used to add finalized-at for queue fixtures).
write_brief() {
    local dir="$1" slug="$2" extra="${3:+$3
}"
    cat >"$dir/$slug.md" <<EOF
---
status: not-started
effort: small
priority: medium
dependencies: []
${extra}---
# $slug

**In brief**: a fixture brief.

## Goal

Exercise the document-format contract.

## Acceptance criteria
<!-- AC:BEGIN — DO NOT REMOVE: /task-finalize, /task-move, and the task-queue worker parse the AC list between these sentinels. -->

- [ ] the fixture brief is valid

<!-- AC:END -->
EOF
}

# A repo whose docs/work/ conforms to the contract.
make_conformant() {
    git_init "$1"
    mkdir -p "$1/docs/work/tasks/now" "$1/docs/work/tasks/soon" \
             "$1/docs/work/tasks/later" "$1/docs/work/tasks/never"
    cat >"$1/docs/work/definition-of-done.md" <<'EOF'
# Definition of done

The evidence required before a change lands in this repo.

| Required evidence | Command | Pass condition |
|------|---------|----------------|
| Tests | bash tests/run-tests.sh | Exit 0 |
EOF
    write_brief "$1/docs/work/tasks/now" "a-fixture-task"
    write_brief "$1/docs/work/tasks/soon" "b-fixture-task"
    write_brief "$1/docs/work/tasks/later" "c-fixture-task"
    write_brief "$1/docs/work/tasks/never" "d-fixture-task"
    git -C "$1" add -A
    git -C "$1" commit -qm "fixture: conformant docs/work"
}

# A repo where none of the migration happened: tasks still at the legacy
# docs/tasks/ root, nothing under docs/work/.
make_unmigrated() {
    git_init "$1"
    mkdir -p "$1/docs/tasks/now" "$1/docs/tasks/soon" \
             "$1/docs/tasks/later" "$1/docs/tasks/never"
    cat >"$1/docs/tasks/definition-of-done.md" <<'EOF'
# Definition of done

Legacy definition-of-done file.
EOF
    write_brief "$1/docs/tasks/now" "legacy-task"
    git -C "$1" add -A
    git -C "$1" commit -qm "fixture: unmigrated legacy tasks"
}

# expect <label> <expected-exit> <mutate-fn> [required-substring]...
# Builds a fresh conformant fixture, applies the mutation (or NONE), runs the
# checker, and asserts the exit class plus every required substring of the
# output.
expect() {
    local label="$1" want="$2" fn="$3" sub
    shift 3
    local d="$TMP/expect-case"
    rm -rf "$d"
    make_conformant "$d"
    if [ "$fn" != "NONE" ]; then
        "$fn" "$d"
    fi
    local out rc=0 missing=0
    out=$(bash "$SCRIPT" "$d" 2>&1) || rc=$?
    if [ "$rc" -ne "$want" ]; then
        fail "$label: exit $rc, wanted $want"
        printf '%s\n' "$out" | sed 's/^/    /'
        return
    fi
    for sub in "$@"; do
        if ! printf '%s\n' "$out" | grep -Fq "$sub"; then
            echo "    missing: $sub"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        fail "$label: expected output text not found"
        printf '%s\n' "$out" | sed 's/^/    /'
        return
    fi
    echo "ok: $label"
}

# --- usage errors: missing, non-directory, non-Git, subdirectory --------------
rc=0
out=$(bash "$SCRIPT" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "missing argument: exit $rc, wanted 2"
printf '%s\n' "$out" | grep -Fq "usage: bash Tools/check-docs-work-conformance.sh" \
    || fail "missing argument: no usage line"

rc=0
out=$(bash "$SCRIPT" "$TMP/does-not-exist" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "nonexistent root: exit $rc, wanted 2"
printf '%s\n' "$out" | grep -Fq "cannot enter" || fail "nonexistent root: no cannot-enter line"

mkdir -p "$TMP/plain-dir"
rc=0
out=$(bash "$SCRIPT" "$TMP/plain-dir" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "non-Git root: exit $rc, wanted 2"
printf '%s\n' "$out" | grep -Fq "not a Git worktree" || fail "non-Git root: no not-a-worktree line"

d="$TMP/subdir-case"
rm -rf "$d"
make_conformant "$d"
mkdir -p "$d/src"
rc=0
out=$(bash "$SCRIPT" "$d/src" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "subdirectory root: exit $rc, wanted 2"
printf '%s\n' "$out" | grep -Fq "not the Git worktree root" || fail "subdirectory root: no not-the-root line"

# --- the unmigrated baseline is RED, for the migration-shaped reasons ---------
d="$TMP/unmigrated"
rm -rf "$d"
make_unmigrated "$d"
out=$(bash "$SCRIPT" "$d" 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "unmigrated baseline: exit $rc, wanted 1"
printf '%s\n' "$out" | grep -Fq "FAIL 1" || fail "unmigrated: no clause-1 failure"
printf '%s\n' "$out" | grep -Fq "docs/work/tasks/ does not exist" || fail "unmigrated: no migrate-tasks message"
printf '%s\n' "$out" | grep -Fq "legacy tasks root docs/tasks/ remains" || fail "unmigrated: no legacy-root message"
printf '%s\n' "$out" | grep -Fq "FAIL 6" || fail "unmigrated: no clause-6 failure"
printf '%s\n' "$out" | grep -Fq "definition-of-done.md is missing" || fail "unmigrated: no definition-of-done migration message"

# --- the complete target is GREEN, with a verdict for every registry row ------
d="$TMP/conformant"
rm -rf "$d"
make_conformant "$d"
out=$(bash "$SCRIPT" "$d" 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "conformant fixture: exit $rc, wanted 0"
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    printf '%s\n' "$out" | grep -Eq "(^| )$n " || fail "conformant: no verdict for clause $n"
done

# --- one mutation per clause ---------------------------------------------------
legacy_tasks_twin() { mkdir -p "$1/docs/tasks/now"; echo x >"$1/docs/tasks/now/stray.md"; }
expect "legacy tasks root retained beside the migration" 1 legacy_tasks_twin \
    "FAIL 1" "legacy tasks root docs/tasks/ remains"

drop_bucket() { rm -rf "$1/docs/work/tasks/never"; }
expect "missing human bucket" 1 drop_bucket "FAIL 1" "missing human bucket docs/work/tasks/never/"

done_bucket() { mkdir -p "$1/docs/work/tasks/done"; }
expect "done/ bucket present" 1 done_bucket "FAIL 1" "done/ bucket present"

remove_dod() { rm "$1/docs/work/definition-of-done.md"; }
expect "definition-of-done missing" 1 remove_dod "FAIL 6" "definition-of-done.md is missing"

dod_heading_only() { printf '# Only a heading\n' >"$1/docs/work/definition-of-done.md"; }
expect "definition-of-done is heading-only" 1 dod_heading_only \
    "FAIL 6" "a heading and 0 line(s) of content"

dod_no_heading() { printf 'just prose\nmore prose\n' >"$1/docs/work/definition-of-done.md"; }
expect "definition-of-done without a level-1 heading" 1 dod_no_heading \
    "FAIL 6" "no level-1 heading"

add_docs_only() {
    cat >>"$1/docs/work/definition-of-done.md" <<'EOF'

<!-- DOCS-ONLY:BEGIN — paths no check in this repo reads. DO NOT REMOVE. -->
docs/
<!-- DOCS-ONLY:END -->
EOF
}
expect "DOCS-ONLY declared is reported, not re-validated" 0 add_docs_only \
    "DOCS-ONLY block present" "Tools/docs-only-diff.sh"

consumed_legacy() { printf 'fleet\n' >"$1/docs/consumed-by.md"; }
expect "consumed-by only at the legacy location" 1 consumed_legacy \
    "FAIL 8" "migrate it to docs/work/consumed-by.md"

consumed_broken() {
    printf '# Consumed by\n\n<!-- CONSUMED-BY:BEGIN -->\n<!-- CONSUMED-BY:END -->\n' \
        >"$1/docs/work/consumed-by.md"
}
expect "consumed-by with an emptied declaration block" 1 consumed_broken \
    "FAIL 8" "broken declaration"

consumed_badline() {
    printf '# Consumed by\n\n<!-- CONSUMED-BY:BEGIN -->\nnot a parent\n<!-- CONSUMED-BY:END -->\n' \
        >"$1/docs/work/consumed-by.md"
}
expect "consumed-by with a line /ship cannot read" 1 consumed_badline \
    "FAIL 8" "each line must be 'fleet' or owner/repo"

consumed_twin() {
    printf 'fleet\n' >"$1/docs/consumed-by.md"
    printf '# Consumed by\n\n<!-- CONSUMED-BY:BEGIN -->\nfleet\n<!-- CONSUMED-BY:END -->\n' \
        >"$1/docs/work/consumed-by.md"
}
expect "legacy consumed-by retained beside the migrated copy" 1 consumed_twin \
    "FAIL 8" "legacy docs/consumed-by.md remains"

add_focus() { printf '# Focus\n\nShip the thing.\n' >"$1/docs/work/tasks/focus.md"; }
expect "focus document present" 0 add_focus "focus.md present" "ranking-rubric"

empty_focus() { : >"$1/docs/work/tasks/focus.md"; }
expect "empty focus document" 1 empty_focus "FAIL 9" "empty or unreadable"

add_queue() { mkdir -p "$1/docs/work/tasks/queued"; }
expect "queue opted in without its README" 1 add_queue \
    "FAIL 10" "queued/README.md is missing"

queue_conformant() {
    mkdir -p "$1/docs/work/tasks/queued"
    echo "# queued" >"$1/docs/work/tasks/queued/README.md"
    sha=$(git -C "$1" rev-parse HEAD)
    write_brief "$1/docs/work/tasks/queued" "queued-task" "finalized-at: $sha"
    git -C "$1" add -A
    git -C "$1" commit -qm "fixture: queue with a finalized brief"
}
expect "queue with README and a finalized brief is green" 0 queue_conformant \
    "queued/README.md present" "finalized-at"

queue_no_finalized() {
    mkdir -p "$1/docs/work/tasks/queued"
    echo "# queued" >"$1/docs/work/tasks/queued/README.md"
    write_brief "$1/docs/work/tasks/queued" "queued-task"
}
expect "queued brief without finalized-at" 1 queue_no_finalized \
    "FAIL 11" "missing finalized-at"

queue_bad_sha() {
    mkdir -p "$1/docs/work/tasks/queued"
    echo "# queued" >"$1/docs/work/tasks/queued/README.md"
    write_brief "$1/docs/work/tasks/queued" "queued-task" \
        "finalized-at: 0123456789abcdef0123456789abcdef01234567"
}
expect "queued brief with a nonexistent finalized-at commit" 1 queue_bad_sha \
    "FAIL 11" "does not name a commit"

brief_missing_status() {
    grep -v '^status:' "$1/docs/work/tasks/now/a-fixture-task.md" >"$1/t" \
        && mv "$1/t" "$1/docs/work/tasks/now/a-fixture-task.md"
}
expect "brief missing the status field" 1 brief_missing_status \
    "FAIL 11" "missing frontmatter field: status"

brief_status_done() {
    sed 's/^status: not-started/status: done/' "$1/docs/work/tasks/now/a-fixture-task.md" \
        >"$1/t" && mv "$1/t" "$1/docs/work/tasks/now/a-fixture-task.md"
}
expect "brief with status: done" 1 brief_status_done "FAIL 11" "status: done is rejected"

brief_bad_effort() {
    sed 's/^effort: small/effort: huge/' "$1/docs/work/tasks/now/a-fixture-task.md" \
        >"$1/t" && mv "$1/t" "$1/docs/work/tasks/now/a-fixture-task.md"
}
expect "brief with an invalid effort value" 1 brief_bad_effort \
    "FAIL 11" "effort: invalid value"

brief_no_sentinels() {
    grep -v 'AC:BEGIN' "$1/docs/work/tasks/now/a-fixture-task.md" >"$1/t" \
        && mv "$1/t" "$1/docs/work/tasks/now/a-fixture-task.md"
}
expect "brief missing the AC:BEGIN sentinel" 1 brief_no_sentinels \
    "FAIL 11" "missing AC:BEGIN sentinel"

# Clause 11 delegates its format parser to task-finalize's bundled checker.
# A human-bucket draft remains valid before finalization, and the queue's
# inline parser already supports this block-list spelling, so the shared parser
# must accept it here as well.
brief_block_dependencies() {
    sed 's/^dependencies: \[\]$/dependencies:\n  - another-task/' \
        "$1/docs/work/tasks/now/a-fixture-task.md" >"$1/t" \
        && mv "$1/t" "$1/docs/work/tasks/now/a-fixture-task.md"
}
expect "human brief with block dependencies through the shared parser" 0 \
    brief_block_dependencies

# The delegated checker returns exit 1 for a malformed brief, but the caller
# runs under set -e and still has to aggregate every bad brief into clause 11's
# stable output rather than aborting at its first failure.
brief_multiple_format_problems() {
    grep -v -e '^status:' -e 'AC:BEGIN' "$1/docs/work/tasks/now/a-fixture-task.md" \
        >"$1/t" && mv "$1/t" "$1/docs/work/tasks/now/a-fixture-task.md"
}
expect "multiple brief-format failures are aggregated" 1 brief_multiple_format_problems \
    "FAIL 11" "missing frontmatter field: status" "missing AC:BEGIN sentinel"

kaizen_legacy() {
    mkdir -p "$1/docs/kaizen/journal/2026-08" "$1/docs/kaizen/patterns"
    echo x >"$1/docs/kaizen/journal/2026-08/2026-08-01-friction.md"
}
expect "legacy kaizen root retained" 1 kaizen_legacy "FAIL 2" "legacy kaizen root docs/kaizen/ remains"

kaizen_no_journal() { mkdir -p "$1/docs/work/kaizen/patterns"; }
expect "kaizen target missing journal/" 1 kaizen_no_journal "FAIL 2" "missing docs/work/kaizen/journal/"

kaizen_migrated() {
    mkdir -p "$1/docs/work/kaizen/journal/2026-08" "$1/docs/work/kaizen/patterns"
    echo x >"$1/docs/work/kaizen/journal/2026-08/2026-08-01-friction.md"
    git -C "$1" add -A
    git -C "$1" commit -qm "fixture: migrated kaizen"
}
expect "migrated kaizen tree is green" 0 kaizen_migrated \
    "docs/work/kaizen/ with journal/ and patterns/"

problems_legacy() {
    mkdir -p "$1/docs/problems"
    echo x >"$1/docs/problems/README.md"
}
expect "legacy problems root retained" 1 problems_legacy "FAIL 3" "legacy problems root docs/problems/ remains"

problems_planning_legacy() {
    mkdir -p "$1/docs/planning/problems"
    echo x >"$1/docs/planning/problems/README.md"
}
expect "planning/problems legacy variant retained" 1 problems_planning_legacy \
    "FAIL 3" "legacy problems root docs/planning/problems/ remains"

problems_planning_migrated() {
    # The post-migration state of the planning/problems variant: target tree
    # in place, legacy root gone.
    mkdir -p "$1/docs/work/problems"
    echo x >"$1/docs/work/problems/README.md"
    git -C "$1" add -A
    git -C "$1" commit -qm "fixture: migrate planning/problems"
}
expect "planning/problems variant migrated is green" 0 problems_planning_migrated \
    "docs/work/problems/ with its README"

problems_no_readme() {
    mkdir -p "$1/docs/work/problems"
    echo x >"$1/docs/work/problems/a-problem.md"
}
expect "problems target missing its README" 1 problems_no_readme \
    "FAIL 3" "README.md is missing"

problems_migrated() {
    mkdir -p "$1/docs/work/problems"
    echo x >"$1/docs/work/problems/README.md"
    git -C "$1" add -A
    git -C "$1" commit -qm "fixture: migrated problems"
}
expect "migrated problems collection is green" 0 problems_migrated \
    "docs/work/problems/ with its README"

handoffs_legacy() {
    mkdir -p "$1/docs/planning/handoffs"
    echo x >"$1/docs/planning/handoffs/pending.md"
}
expect "legacy handoff outbox retained" 1 handoffs_legacy \
    "FAIL 4" "legacy outbox docs/planning/handoffs/ remains"

handoffs_migrated() {
    mkdir -p "$1/docs/work/handoffs"
    echo x >"$1/docs/work/handoffs/README.md"
    git -C "$1" add -A
    git -C "$1" commit -qm "fixture: migrated outbox"
}
expect "migrated handoff outbox is green" 0 handoffs_migrated "docs/work/handoffs/ present"

handoff_content_keyed() {
    mkdir -p "$1/somewhere"
    printf -- '---\nhandoff-to: OMGBrews/elsewhere\n---\n' >"$1/somewhere/pending.md"
    git -C "$1" add -A
    git -C "$1" commit -qm "fixture: pending handoff brief"
}
expect "a handoff-to: brief anywhere activates the clause" 1 handoff_content_keyed \
    "FAIL 4" "docs/work/handoffs/ does not exist"

thoughts_legacy() {
    mkdir -p "$1/docs/planning/thoughts"
    echo x >"$1/docs/planning/thoughts/note.md"
}
expect "legacy thought inbox retained" 1 thoughts_legacy \
    "FAIL 5" "legacy inbox docs/planning/thoughts/ remains"

thoughts_migrated() {
    mkdir -p "$1/docs/work/thoughts"
    echo x >"$1/docs/work/thoughts/note.md"
    git -C "$1" add -A
    git -C "$1" commit -qm "fixture: migrated inbox"
}
expect "migrated thought inbox is green" 0 thoughts_migrated "docs/work/thoughts/ present"

consumed_migrated() {
    printf '# Consumed by\n\n<!-- CONSUMED-BY:BEGIN -->\nfleet\n<!-- CONSUMED-BY:END -->\n' \
        >"$1/docs/work/consumed-by.md"
}
expect "migrated consumed-by declaration is green" 0 consumed_migrated "declares: fleet"

# --- clause 16: docs/work/audits/ (opt-in via the declaring config) -----------
audits_dir_only() { mkdir -p "$1/docs/work/audits"; }
expect "audits directory without its declaring config" 1 audits_dir_only \
    "FAIL 16" "config.toml is missing or empty"

audits_config_without_records() {
    mkdir -p "$1/docs/work/audits"
    printf '[audit_types.code-quality]\ndescription = "x"\n' >"$1/docs/work/audits/config.toml"
}
expect "audits config without a records directory" 1 audits_config_without_records \
    "FAIL 16" "records/ does not exist"

audits_green() {
    mkdir -p "$1/docs/work/audits/records"
    printf '[audit_types.code-quality]\ndescription = "x"\n' >"$1/docs/work/audits/config.toml"
    printf '{"pick_counter": 0, "audits": {}}\n' >"$1/docs/work/audits/records/code-quality.json"
}
expect "opted-in audits tree is green" 0 audits_green \
    "declaring config and parseable records"

audits_bad_record() {
    mkdir -p "$1/docs/work/audits/records"
    printf '[audit_types.code-quality]\n' >"$1/docs/work/audits/config.toml"
    printf 'not json at all\n' >"$1/docs/work/audits/records/code-quality.json"
}
expect "unparseable audit record named" 1 audits_bad_record \
    "FAIL 16" "not valid JSON"

# Absent is a verdict too: an unopted-in repo must still print clause 16's line.
audits_absent_visible() { :; }
expect "unopted-in repo reports clause 16 as absent" 0 audits_absent_visible \
    "absent 16"

if [ "$failures" -ne 0 ]; then
    echo "$failures assertion(s) failed" >&2
    exit 1
fi
echo "all check-docs-work-conformance assertions passed"
