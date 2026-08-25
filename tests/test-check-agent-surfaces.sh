#!/usr/bin/env bash
# Tests for Tools/check-agent-surfaces.sh — the check that mechanizes checks 1-9
# and 13-14 of workshop/docs/harness-agnostic-repos.md.
#
# The headline case is `nothing was done`: a repo with a lone CLAUDE.md and its
# skills authored under .claude/skills/ — exactly the shape the standard exists to
# replace. A conformance script that goes green there is worse than no script,
# because its green ends the investigation. So that fixture is asserted red first,
# and every other case then mutates ONE property of a conformant fixture and
# asserts that the check owning it is the one that fires, by number. Asserting
# only "non-zero" would stay green if every mutation started failing for the same
# unrelated reason.
#
# The fixtures are plain directories, not git repos: the script reads .gitmodules
# with `git config -f`, which needs no repository.
#
# shellcheck disable=SC2016  # the single-quoted backticks below are Markdown, not
#                              command substitution — expansion is exactly what must
#                              not happen to them.
set -euo pipefail

DEVTOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DEVTOOLS_ROOT/Tools/check-agent-surfaces.sh"

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# A repo that satisfies all ten checks. Deliberately includes the two @-shaped
# strings real instruction files carry — an address inside a fenced block and a
# scoped npm package inside a code span — because a naive '@' grep calls both
# imports and fails check 4 on a conformant repo.
make_conformant() {
    local d=$1
    mkdir -p "$d/workshop/docs" "$d/.agents/skills/demo" "$d/.claude/skills"
    cat > "$d/AGENTS.md" <<'EOF'
# Instructions

Everything every agent needs. Standing rules:

- [`workshop/docs/signal-hygiene.md`](workshop/docs/signal-hygiene.md)
- [`workshop/docs/definition-of-done.md`](workshop/docs/definition-of-done.md)
- [`workshop/docs/verification-terminology.md`](workshop/docs/verification-terminology.md)

```bash
psql postgresql://user:pass@localhost:5432/db
```

The frontend uses `@scope/package` for auth.
EOF
    cat > "$d/CLAUDE.md" <<'EOF'
# Bridge

@AGENTS.md
@workshop/docs/signal-hygiene.md
@workshop/docs/definition-of-done.md
@workshop/docs/verification-terminology.md
EOF
    echo 'Signal hygiene.' > "$d/workshop/docs/signal-hygiene.md"
    echo 'Definition of done.' > "$d/workshop/docs/definition-of-done.md"
    echo 'Verification terminology.' > "$d/workshop/docs/verification-terminology.md"
    cat > "$d/.agents/skills/demo/SKILL.md" <<'EOF'
---
name: demo
description: A demo skill, used when the tests need one.
---

Body.
EOF
    ln -s ../../.agents/skills/demo "$d/.claude/skills/demo"
}

# A repo where none of the work was done: no AGENTS.md, no bridge, no canonical
# skills path — the skill is a real directory only Claude Code can run.
make_unmigrated() {
    local d=$1
    mkdir -p "$d/.claude/skills/demo"
    cat > "$d/CLAUDE.md" <<'EOF'
# Project

Everything every agent needs, in the one vendor's file.
EOF
    cat > "$d/.claude/skills/demo/SKILL.md" <<'EOF'
---
name: demo
description: A demo skill.
---
EOF
}

# expect <label> <expected-exit> <mutate-fn> [required-substring] [forbidden-substring]
#
# `mutate-fn` runs inside a fresh conformant fixture. Pass the literal NONE to
# assert the unmutated fixture, or a builder name prefixed with build: to replace
# the fixture entirely. The forbidden substring exists for cases where the right
# outcome is the ABSENCE of a line class — e.g. check 13's notes, which do not
# move the exit code and so cannot be ruled out by it.
expect() {
    local label=$1 want=$2 mutate=$3 needle=${4-} antineedle=${5-}
    local tmp out actual=0
    tmp="$(mktemp -d)"
    case "$mutate" in
        build:*) "${mutate#build:}" "$tmp" ;;
        *)
            make_conformant "$tmp"
            [ "$mutate" = NONE ] || (cd "$tmp" && "$mutate")
            ;;
    esac
    out="$(bash "$SCRIPT" "$tmp" 2>&1)" || actual=$?
    if [ "$actual" -ne "$want" ]; then
        fail "$label: expected exit $want, got $actual"
        printf '%s\n' "$out" | sed 's/^/    | /' >&2
    elif [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF "$needle"; then
        fail "$label: exit $actual as expected, but the output never said '$needle'"
        printf '%s\n' "$out" | sed 's/^/    | /' >&2
    elif [ -n "$antineedle" ] && printf '%s' "$out" | grep -qF "$antineedle"; then
        fail "$label: exit $actual as expected, but the output said '$antineedle'"
        printf '%s\n' "$out" | sed 's/^/    | /' >&2
    fi
    rm -rf "$tmp"
}

# --- the case that matters most ----------------------------------------------
expect "a repo where none of the work was done is RED" 1 build:make_unmigrated
# ...and red for the right reasons, not incidentally.
expect "unmigrated: no AGENTS.md"        1 build:make_unmigrated "FAIL 1"
expect "unmigrated: no bridge import"    1 build:make_unmigrated "FAIL 2"
expect "unmigrated: skills only Claude can run" 1 build:make_unmigrated "FAIL 7"

# --- the conformant fixture is green, or every case below is meaningless -----
expect "a conformant repo is green" 0 NONE

# --- one mutation per check ---------------------------------------------------
wrapper_outgrows_root() { printf '%.0spadding padding padding\n' {1..80} >> CLAUDE.md; }
drop_bridge_import()    { grep -v '^@AGENTS\.md$' CLAUDE.md > t && mv t CLAUDE.md; }
unlink_standing_rule()  { sed 's|\[`workshop/docs/signal-hygiene.md`\](workshop/docs/signal-hygiene.md)|the signal-hygiene rule|' AGENTS.md > t && mv t AGENTS.md; }
import_from_root()      { echo '@workshop/docs/signal-hygiene.md' >> AGENTS.md; }
oversize_root()         { printf '%.0sx%.0s\n' {1..21000} >> AGENTS.md; }
add_per_tool_file()     { echo 'be helpful' > .cursorrules; }
skill_only_for_claude() { mkdir -p .claude/skills/local && echo body > .claude/skills/local/SKILL.md; }
misaimed_bridge_link()  { rm .claude/skills/demo && ln -s ../../docs .claude/skills/demo; }
dangling_bridge_link()  { rm -rf .agents/skills/demo; }
nonspec_frontmatter()   { sed 's/^description:/disable-model-invocation: true\ndescription:/' .agents/skills/demo/SKILL.md > t && mv t .agents/skills/demo/SKILL.md; }
name_mismatch()         { sed 's/^name: demo/name: something-else/' .agents/skills/demo/SKILL.md > t && mv t .agents/skills/demo/SKILL.md; }
vanished_import()       { rm workshop/docs/signal-hygiene.md; }
drop_terminology_import() { grep -v '^@workshop/docs/verification-terminology\.md$' CLAUDE.md > t && mv t CLAUDE.md; }
unlink_terminology() { grep -v 'verification-terminology\.md' AGENTS.md > t && mv t AGENTS.md; }
drop_terminology_pair() { drop_terminology_import; unlink_terminology; }
split_standing_routes() {
    mkdir -p alternate/docs
    cp workshop/docs/definition-of-done.md alternate/docs/definition-of-done.md
    sed 's|@workshop/docs/definition-of-done.md|@alternate/docs/definition-of-done.md|' CLAUDE.md > t && mv t CLAUDE.md
    sed 's|workshop/docs/definition-of-done.md|alternate/docs/definition-of-done.md|g' AGENTS.md > t && mv t AGENTS.md
}

expect "wrapper larger than root"            1 wrapper_outgrows_root "FAIL 1"
expect "no @AGENTS.md in the wrapper"        1 drop_bridge_import    "FAIL 2"
expect "imported doc not linked from AGENTS" 1 unlink_standing_rule  "FAIL 3"
expect "@-import inside AGENTS.md"           1 import_from_root      "FAIL 4"
expect "root file over the size target"      1 oversize_root         "FAIL 5"
expect "per-tool instruction file present"   1 add_per_tool_file     "FAIL 6"
expect "skill authored under .claude/skills" 1 skill_only_for_claude "FAIL 7"
expect "bridge link aimed elsewhere"         1 misaimed_bridge_link  "FAIL 8"
expect "bridge link left dangling"           1 dangling_bridge_link  "FAIL 8"
expect "frontmatter field outside the spec"  1 nonspec_frontmatter   "FAIL 9"
expect "skill name not matching its dir"     1 name_mismatch         "FAIL 9"

# An import whose target simply is not there fails silently in Claude Code — the
# session runs without the rule and says nothing. It is check 5's business
# because that is where the pile is walked, and it must not be mistaken for the
# uninitialized-submodule case below.
expect "imported doc missing entirely" 1 vanished_import "FAIL 5"

# --- check 14: the third standing rule cannot disappear as a pair -----------
# Check 3 catches an import with no plain link, but both surfaces removed
# together used to look conformant. That is the negative control that matters.
expect "terminology import removed" 1 drop_terminology_import "FAIL 14"
expect "terminology AGENTS link removed" 1 unlink_terminology "FAIL 14"
expect "terminology delivery pair removed" 1 drop_terminology_pair "FAIL 14"
expect "standing rules split across mount routes" 1 split_standing_routes "FAIL 14"

# --- check 13: harness-only mechanics in SKILL.md bodies ---------------------
# The three shapes the standard forbids unless `compatibility` is declared:
# `$ARGUMENTS`, a bare slash-invocation in prose, and the Claude-only
# frontmatter keys. Quoting the same tokens in backticks is documentation —
# the house form — and must pass clean, notes included.
skill_uses_arguments() { printf '%s\n' 'Parse the scope from $ARGUMENTS (defaults to all).' >> .agents/skills/demo/SKILL.md; }
declares_compatibility() { sed 's/^description:/compatibility: Written for Claude Code; the body relies on its argument substitution.\ndescription:/' .agents/skills/demo/SKILL.md > t && mv t .agents/skills/demo/SKILL.md; }
arguments_with_escape()  { skill_uses_arguments; declares_compatibility; }
skill_invokes_slash()    { printf '%s\n' 'When the review is done, run /ship merge to land it.' >> .agents/skills/demo/SKILL.md; }
skill_quotes_ship()      { printf '%s\n' 'The `/ship` skill documents the merge sequence; do not run it here.' >> .agents/skills/demo/SKILL.md; }
slash_in_fence()         { printf '```bash\n/ship merge\n```\n' >> .agents/skills/demo/SKILL.md; }

expect '$ARGUMENTS in a skill body, no escape hatch' 1 skill_uses_arguments "FAIL 13"
expect '$ARGUMENTS with declared compatibility is a note, not a fail' 0 arguments_with_escape "note 13"
expect 'the note says why it is not a failure'     0 arguments_with_escape "declared compatibility"
expect 'bare slash-invocation in prose'            1 skill_invokes_slash "FAIL 13"
expect 'slash token quoted in backticks is documentation' 0 skill_quotes_ship "ok   13" "note 13"
expect 'slash token inside a fenced block is documentation' 0 slash_in_fence "ok   13" "note 13"
# The nonspec_frontmatter mutation above adds exactly `disable-model-invocation`:
# check 9 rejects the field as outside the spec set, and 13 names the same key
# as Claude-only. One root cause, two statements of it.
expect 'Claude-only frontmatter key' 1 nonspec_frontmatter "FAIL 13"

# --- a plain file on a skills surface is not a skill -------------------------
# `sync-skill-symlinks.sh` generates .claude/skills/README.md, the signpost
# saying the folder is symlinks and skills are authored in .agents/skills/.
# Checks 7 and 8 walk that directory, and before they learned to skip regular
# files the signpost itself read as a bridge entry with no canonical twin — the
# check failed in every repo that carried one, and the sentence explaining the
# rule was the thing breaking the rule's own check.
bridge_readme()    { echo '# bridge' > .claude/skills/README.md; }
canonical_readme() { echo '# canonical' > .agents/skills/README.md; }
surface_readmes()  { bridge_readme; canonical_readme; }

expect 'a README beside the bridge links is not counted as a skill' \
    0 bridge_readme ".agents/skills/ holds 1 skill(s), .claude/skills/ bridges 1"
expect 'a README beside the bridge links is not link-checked' \
    0 bridge_readme "ok   8" "README.md"
expect 'a README on either surface leaves the check green' 0 surface_readmes
expect 'a README on the canonical surface is not validated as a skill' \
    0 surface_readmes "ok   9" "README.md"

# --- the skipped band ---------------------------------------------------------
# A consumer's CI may check a repo out WITHOUT submodules on purpose (devtools/ is
# private), so the shared skills and the standing-rules import are both unreadable
# there. That must report SKIP and stay exit 0 — but it must never report those
# assertions as passes, because a silent skip and a satisfied check would then look
# identical.
make_unpopulated_submodule() {
    local d=$1
    make_conformant "$d"
    mkdir -p "$d/sub" "$d/vendor/.agents/skills"
    cat > "$d/.gitmodules" <<'EOF'
[submodule "sub"]
	path = sub
	url = https://example.invalid/sub.git
EOF
    echo '@sub/rule.md' >> "$d/CLAUDE.md"
    # Check 3 applies to the submodule-backed rule too: the link must be there
    # even though the target cannot be read right now.
    echo 'Second standing rule: [`sub/rule.md`](sub/rule.md).' >> "$d/AGENTS.md"
    # A shared skill bridged through the canonical path into the empty submodule.
    ln -s ../../sub/skills/shared "$d/.agents/skills/shared"
    ln -s ../../.agents/skills/shared "$d/.claude/skills/shared"
}
expect "uninitialized submodule is a SKIP, not a pass" 0 build:make_unpopulated_submodule "SKIP"
expect "the skip is announced as not-a-pass"           0 build:make_unpopulated_submodule "A skip is not a pass."
# The same missing file WITHOUT the .gitmodules declaration is a failure, which
# is the distinction the skip band exists to make.
make_missing_no_submodule() {
    make_unpopulated_submodule "$1"
    rm "$1/.gitmodules"
}
expect "the same gap without a submodule declaration is RED" 1 build:make_missing_no_submodule

if [ "$failures" -ne 0 ]; then
    echo "$failures assertion(s) failed" >&2
    exit 1
fi
echo "all check-agent-surfaces assertions passed"
