#!/usr/bin/env bash
# Tests for Tools/check-agent-surfaces.sh — the check that mechanizes checks 1-9
# and 13 of workshop/docs/harness-agnostic-repos.md.
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
# Each fixture is built at $tmp/repo, never at $tmp itself: check 1 walks every
# ancestor up to /, so the suppressor mutations write into the fixture's parent,
# and that parent has to be a directory this test owns. The fixtures are plain
# directories, not git repos: the script reads .gitmodules with `git config -f`,
# which needs no repository.
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

# A repo that satisfies every check: AGENTS.md linking the three standing rules,
# the rules mounted under workshop/docs/ with their headings on line one, and
# the three .claude/rules/ links into them. Deliberately includes the two
# @-shaped strings real instruction files carry — an address inside a fenced
# block and a scoped npm package inside a code span — because a naive '@' grep
# calls both imports and fails check 4 on a conformant repo.
make_conformant() {
    local d=$1
    mkdir -p "$d/workshop/docs" "$d/.agents/skills/demo" "$d/.claude/skills" "$d/.claude/rules"
    cat > "$d/AGENTS.md" <<'EOF2'
# Instructions

Everything every agent needs. Standing rules:

- [`workshop/docs/signal-hygiene.md`](workshop/docs/signal-hygiene.md)
- [`workshop/docs/definition-of-done.md`](workshop/docs/definition-of-done.md)
- [`workshop/docs/verification-terminology.md`](workshop/docs/verification-terminology.md)

```bash
psql postgresql://user:pass@localhost:5432/db
```

The frontend uses `@scope/package` for auth.
EOF2
    printf '# Signal hygiene\n\nBody.\n' > "$d/workshop/docs/signal-hygiene.md"
    printf '# Definition of done\n\nBody.\n' > "$d/workshop/docs/definition-of-done.md"
    printf '# Verification terminology\n\nBody.\n' > "$d/workshop/docs/verification-terminology.md"
    local rule
    for rule in signal-hygiene definition-of-done verification-terminology; do
        ln -s "../../workshop/docs/$rule.md" "$d/.claude/rules/$rule.md"
    done
    cat > "$d/.agents/skills/demo/SKILL.md" <<'EOF2'
---
name: demo
description: A demo skill, used when the tests need one.
---

Body.
EOF2
    ln -s ../../.agents/skills/demo "$d/.claude/skills/demo"
}

# A repo where none of the work was done: no AGENTS.md, no rules links, no
# canonical skills path — the skill is a real directory only Claude Code can run.
make_unmigrated() {
    local d=$1
    mkdir -p "$d/.claude/skills/demo"
    cat > "$d/CLAUDE.md" <<'EOF2'
# Project

Everything every agent needs, in the one vendor's file.
EOF2
    cat > "$d/.claude/skills/demo/SKILL.md" <<'EOF2'
---
name: demo
description: A demo skill.
---
EOF2
}

# expect <label> <expected-exit> <mutate-fn> [required-substring] [forbidden-substring]
#
# `mutate-fn` runs inside a fresh conformant fixture at $tmp/repo. Pass the
# literal NONE to assert the unmutated fixture, or a builder name prefixed with
# build: to replace the fixture entirely. A mutation prefixed with home: also
# runs the check with HOME set to the fixture's parent, for the user-memory
# cases. The forbidden substring exists for cases where the right outcome is
# the ABSENCE of a line class — e.g. check 13's notes, which do not move the
# exit code and so cannot be ruled out by it.
expect() {
    local label=$1 want=$2 mutate=$3 needle=${4-} antineedle=${5-}
    local tmp repo out actual=0 home=$HOME
    tmp="$(mktemp -d)"
    repo="$tmp/repo"
    mkdir -p "$repo"
    case "$mutate" in
        home:*) home=$tmp; mutate=${mutate#home:} ;;
    esac
    case "$mutate" in
        build:*) "${mutate#build:}" "$repo" ;;
        *)
            make_conformant "$repo"
            [ "$mutate" = NONE ] || (cd "$repo" && "$mutate")
            ;;
    esac
    out="$(HOME=$home bash "$SCRIPT" "$repo" 2>&1)" || actual=$?
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
expect "unmigrated: its CLAUDE.md named as a suppressor" 1 build:make_unmigrated "/repo/CLAUDE.md exists"
expect "unmigrated: no AGENTS.md"        1 build:make_unmigrated "AGENTS.md is missing"
expect "unmigrated: no standing-rule links" 1 build:make_unmigrated "FAIL 2"
expect "unmigrated: skills only Claude can run" 1 build:make_unmigrated "FAIL 7"

# --- the conformant fixture is green, or every case below is meaningless -----
expect "a conformant repo is green" 0 NONE

# --- check 1: AGENTS.md, and no suppressor from the root up to / -------------
# Any one of these switches Claude Code's native AGENTS.md reading off for
# everything beneath it, while the rules links keep loading: nothing looks
# broken. The walk must find it at the root, in .claude/, and above the root.
drop_agents()          { rm AGENTS.md; }
local_suppressor()     { echo 'personal notes' > CLAUDE.local.md; }
root_bridge()          { printf '@AGENTS.md\n' > CLAUDE.md; }
dotclaude_suppressor() { echo 'notes' > .claude/CLAUDE.md; }
parent_suppressor()    { echo 'workspace bridge' > ../CLAUDE.md; }
user_memory()          { mkdir -p ../.claude && echo 'my preferences' > ../.claude/CLAUDE.md; }

expect "no AGENTS.md"                         1 drop_agents          "FAIL 1"
expect "CLAUDE.local.md at the root"          1 local_suppressor     "/repo/CLAUDE.local.md exists"
expect "a CLAUDE.md bridge left at the root"  1 root_bridge          "/repo/CLAUDE.md exists"
expect ".claude/CLAUDE.md"                    1 dotclaude_suppressor "/repo/.claude/CLAUDE.md exists"
expect "CLAUDE.md in a parent directory"      1 parent_suppressor    "FAIL 1"
# ~/.claude/CLAUDE.md is per-user memory, verified not to switch AGENTS.md off;
# a plain ~/CLAUDE.md is an ordinary ancestor and does.
expect "user memory under HOME is exempt"     0 home:user_memory     "ok   1"
expect "a plain CLAUDE.md in HOME is not"     1 home:parent_suppressor "FAIL 1"

# --- check 2: each standing rule resolves through one route -------------------
drop_rule_link()   { rm .claude/rules/definition-of-done.md; }
dangling_rule()    { rm workshop/docs/signal-hygiene.md; }
wrong_document()   {
    printf 'Notes\n' > workshop/docs/notes.md
    ln -sfn ../../workshop/docs/notes.md .claude/rules/signal-hygiene.md
}
wrong_heading()    { printf 'Signal hygiene, retitled\n' > workshop/docs/signal-hygiene.md; }
copied_rule()      { rm .claude/rules/signal-hygiene.md && cp workshop/docs/signal-hygiene.md .claude/rules/; }
split_routes()     {
    mkdir -p alternate/docs
    cp workshop/docs/definition-of-done.md alternate/docs/
    ln -sfn ../../alternate/docs/definition-of-done.md .claude/rules/definition-of-done.md
    sed 's|workshop/docs/definition-of-done.md|alternate/docs/definition-of-done.md|g' AGENTS.md > t && mv t AGENTS.md
}
two_component_route() {
    mkdir -p wrapper/nested/docs
    cp workshop/docs/*.md wrapper/nested/docs/
    local rule
    for rule in signal-hygiene definition-of-done verification-terminology; do
        ln -sfn "../../wrapper/nested/docs/$rule.md" ".claude/rules/$rule.md"
    done
    sed 's|workshop/docs/|wrapper/nested/docs/|g' AGENTS.md > t && mv t AGENTS.md
}
no_rules_dir()     { rm -rf .claude/rules; }

expect "a standing-rule link deleted"         1 drop_rule_link    "FAIL 2"
expect "a standing-rule link dangling"        1 dangling_rule     "does not resolve"
expect "a link landing on the wrong document" 1 wrong_document    "FAIL 2"
expect "a rule whose first line is wrong"     1 wrong_heading     "not '# Signal hygiene'"
expect "a copied rule instead of a link"      1 copied_rule       "is a real file"
expect "standing rules split across routes"   1 split_routes      "different routes"
expect "a route with two mount components"    1 two_component_route "FAIL 2"
# The never-skip property: a repo with no rules folder at all is a failure per
# rule, never "not applicable" and never a skip.
expect "no .claude/rules/ at all is RED"      1 no_rules_dir      "FAIL 2" "SKIP"
expect "no .claude/rules/ names every rule"   1 no_rules_dir      "verification-terminology.md is missing"

# --- check 3: every rules link is linked from AGENTS.md ----------------------
unlink_standing_rule() { sed 's|\[`workshop/docs/signal-hygiene.md`\](workshop/docs/signal-hygiene.md)|the signal-hygiene rule|' AGENTS.md > t && mv t AGENTS.md; }
unlinked_local_rule()  {
    mkdir -p docs && printf '# Database hygiene\n' > docs/database-hygiene.md
    ln -s ../../docs/database-hygiene.md .claude/rules/database-hygiene.md
}
linked_local_rule()    { unlinked_local_rule; echo 'Also: [database hygiene](docs/database-hygiene.md).' >> AGENTS.md; }
topic_file()           { printf '# Cloud sessions\n\nClaude-only notes.\n' > .claude/rules/cloud-sessions.md; }

expect "a standing rule not linked from AGENTS" 1 unlink_standing_rule "FAIL 3"
expect "a hand-made rules link not in AGENTS"   1 unlinked_local_rule  "docs/database-hygiene.md"
expect "a hand-made rules link in AGENTS"       0 linked_local_rule    "all 4 rules link(s)"
expect "a real topic file needs no AGENTS link" 0 topic_file           "ok   3"

# --- check 4 -----------------------------------------------------------------
import_from_root() { echo '@workshop/docs/signal-hygiene.md' >> AGENTS.md; }
expect "@-import inside AGENTS.md"            1 import_from_root  "FAIL 4"

# --- check 5: the pile, measured through the links ---------------------------
oversize_root()    { printf '%.0sx%.0s\n' {1..21000} >> AGENTS.md; }
oversize_rule()    { printf '%.0spadding padding padding padding\n' {1..1100} >> workshop/docs/verification-terminology.md; }
path_scoped_rule() {
    { printf -- '---\npaths:\n  - "src/**"\n---\n\n# Source notes\n'; printf '%.0spadding padding padding padding\n' {1..1100}; } > .claude/rules/source-notes.md
}
expect "root file over the size target"       1 oversize_root     "FAIL 5"
expect "a rule padded past the pile cap"      1 oversize_rule     "exceeds the 32768 B cap"
expect "a paths: rule is not in the pile"     0 path_scoped_rule  "1 path-scoped rule(s) not counted"
expect "the pile is reported, never skipped"  0 NONE              "AGENTS.md + 3 rule file(s)" "SKIP"

# --- checks 6 to 9 -----------------------------------------------------------
add_per_tool_file()     { echo 'be helpful' > .cursorrules; }
skill_only_for_claude() { mkdir -p .claude/skills/local && echo body > .claude/skills/local/SKILL.md; }
misaimed_bridge_link()  { rm .claude/skills/demo && ln -s ../../docs .claude/skills/demo; }
dangling_bridge_link()  { rm -rf .agents/skills/demo; }
nonspec_frontmatter()   { sed 's/^description:/disable-model-invocation: true\ndescription:/' .agents/skills/demo/SKILL.md > t && mv t .agents/skills/demo/SKILL.md; }
name_mismatch()         { sed 's/^name: demo/name: something-else/' .agents/skills/demo/SKILL.md > t && mv t .agents/skills/demo/SKILL.md; }

expect "per-tool instruction file present"   1 add_per_tool_file     "FAIL 6"
expect "skill authored under .claude/skills" 1 skill_only_for_claude "FAIL 7"
expect "bridge link aimed elsewhere"         1 misaimed_bridge_link  "FAIL 8"
expect "bridge link left dangling"           1 dangling_bridge_link  "FAIL 8"
expect "frontmatter field outside the spec"  1 nonspec_frontmatter   "FAIL 9"
expect "skill name not matching its dir"     1 name_mismatch         "FAIL 9"

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
# Skill bodies that live in an uninitialized submodule cannot be read, so checks
# 8, 9 and 13 report SKIP and stay exit 0 — but they must never report those
# assertions as passes, because a silent skip and a satisfied check would then
# look identical. The standing rules get no such band: see the last case below.
make_unpopulated_submodule() {
    local d=$1
    make_conformant "$d"
    mkdir -p "$d/sub" "$d/vendor/.agents/skills"
    cat > "$d/.gitmodules" <<'EOF'
[submodule "sub"]
	path = sub
	url = https://example.invalid/sub.git
EOF
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
# The standing rules have no skip band: a rules link into an empty mount is a
# session running without its rules, so it fails even when the mount is a
# declared, uninitialized submodule.
make_rules_in_empty_submodule() {
    local d=$1 rule
    make_unpopulated_submodule "$d"
    for rule in signal-hygiene definition-of-done verification-terminology; do
        ln -sfn "../../sub/docs/$rule.md" "$d/.claude/rules/$rule.md"
    done
    sed 's|workshop/docs/|sub/docs/|g' "$d/AGENTS.md" > "$d/t" && mv "$d/t" "$d/AGENTS.md"
}
expect "rules links into an empty submodule are RED" 1 build:make_rules_in_empty_submodule "does not resolve" "SKIP 2"

if [ "$failures" -ne 0 ]; then
    echo "$failures assertion(s) failed" >&2
    exit 1
fi
echo "all check-agent-surfaces assertions passed"
