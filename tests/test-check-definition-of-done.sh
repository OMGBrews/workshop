#!/usr/bin/env bash
# Tests for Tools/check-definition-of-done.sh — the check that holds a
# repository's docs/work/definition-of-done.md to docs/definition-of-done-schema.md.
#
# One conformant fixture per profile is asserted green first; every negative
# then mutates ONE property of a conformant fixture and asserts the clause
# number and the identifying text, so a wrong-but-nonzero exit (every mutation
# failing for one unrelated reason) cannot read as coverage. Each mutation
# refuses to run if the text it replaces is absent, so a fixture edit cannot
# silently turn a negative into a copy of the positive.
#
# The positives for command resolution are the other half of the proof: the
# same page passes once the artifact it names is tracked, so a red result is
# the artifact's absence, not the check's blindness.
#
# Every fixture is a real Git repository: commands resolve against tracked
# files, and submodule behaviour needs real gitlinks.
#
# shellcheck disable=SC2016  # backticks and $vars below are fixture text.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$WORKSHOP_ROOT/Tools/check-definition-of-done.sh"
CONFORMANCE="$WORKSHOP_ROOT/Tools/check-docs-work-conformance.sh"
TEMPLATE="$WORKSHOP_ROOT/docs/templates/definition-of-done.md"

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in "$SCRIPT" "$CONFORMANCE" "$TEMPLATE"; do
    [ -f "$f" ] || { echo "PRECONDITION FAILED: $f is missing" >&2; exit 1; }
done

git_init() {
    git init -q -b main "$1"
    git -C "$1" config user.email check@test
    git -C "$1" config user.name check
}
commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "${2:-fixture}"; }

# replace <file> <old> <new>: exact text replacement that fails loudly when
# <old> is absent, so a mutation can never silently become a no-op.
replace() {
    python3 - "$@" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
if old not in text:
    sys.exit(f"mutation target not found in {path}: {old!r}")
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
}

# --- the four profile fixtures --------------------------------------------------

# Content or scaffold: the complete example page from the template's guidance
# comment, de-indented, so this fixture cannot drift from the template.
page_scaffold() {
    awk '
        /^ +# Definition of done$/ && !p { p = 1; match($0, /^ +/); n = RLENGTH }
        p && /^-->/ { exit }
        p { print substr($0, n + 1) }
    ' "$TEMPLATE"
}

page_local() {
    cat <<'EOF'
# Definition of done

The evidence required before a change to this tool counts as done.

## Repository profile

- Declared unit: `example/tool`, a standalone clone.
- Profile: [active local software](../../workshop/docs/verification-profiles.md#profiles).
- Production evidence: Not applicable — active local software.
- Default landing route: authorized direct push.
- Landing enforcement: procedural.
- Enforcement evidence: nothing blocks a push to `main`; the procedure is
  this page.
- Strengthened for: none.

## Pre-commit feedback

None — no hooks or local checks are configured.

## Landing requirements

- **Verification suite**
  - Command: `make check`
  - Pass condition: exit 0 from a standalone clone.
  - Applies to: every change.
  - Evidence type: automated
  - Enforcement: procedural
  - Evidence state: available
  - CI status: none
- **Shell lint**
  - Command: `bash scripts/lint.sh`
  - Pass condition: exit 0 after reading
    every tracked shell script.
  - Applies to: shell scripts.
  - Evidence type: automated
  - Enforcement: advisory
  - Evidence state: available
  - CI status: none

### Docs-only surface

<!-- DOCS-ONLY:BEGIN — paths no check in this repo reads. DO NOT REMOVE. -->
docs/
<!-- DOCS-ONLY:END -->

## Release requirements

Not applicable — nothing is released or published.

## Deployment requirements

Not applicable — nothing is deployed.

## Known gaps

- No CI runs the suite; landing is procedural.
EOF
}

page_shared() {
    cat <<'EOF'
# Definition of done

The evidence required before a change to this library counts as done.

## Repository profile

- Declared unit: `example/lib`, consumed as a pinned submodule.
- Profile: shared or released software.
- Production evidence: Not applicable — shared or released software.
- Default landing route: pull request.
- Landing enforcement: platform-enforced.
- Enforcement evidence: GitHub ruleset `protect main` (id 1), enforcement
  active, no bypass actors, requiring `check`. Observed by the maintainer on
  2026-09-07 through `gh api repos/example/lib/rulesets/1`.
- Strengthened for: none.

## Pre-commit feedback

None — no hooks are configured.

## Landing requirements

- **Verification suite**
  - Command: `make check`
  - Pass condition: exit 0 from a standalone clone.
  - Applies to: every change.
  - Evidence type: automated
  - Enforcement: platform-enforced
  - Evidence state: available
  - CI status: `check`, from `.github/workflows/check.yml`.

Authorization to merge is separate and is not declared here.

### Docs-only surface

No docs-only surface is declared; every check is presumed to read every path.

## Release requirements

- **Verified release commit**
  - Command: `make check`
  - Pass condition: exit 0 at the exact commit being tagged.
  - Applies to: every release tag.
  - Evidence type: automated
  - Enforcement: procedural
  - Evidence state: available
- **Immutable release identity**
  - Command: none
  - Pass condition: the maintainer tags the verified commit and never moves the tag.
  - Applies to: every release tag.
  - Evidence type: manual
  - Enforcement: procedural
  - Evidence state: available

## Deployment requirements

Not applicable — consumers pin commits and own their deployments.

## Known gaps

None — tag protection was looked for and none is needed while consumers pin commits.
EOF
}

page_production() {
    cat <<'EOF'
# Definition of done

The evidence required before a change to this service counts as done.

## Repository profile

- Declared unit: `example/service`, a standalone clone.
- Profile: production or deployed system.
- Production evidence: the maintainer operates https://service.example.test;
  `docs/deploys.md` records every deployment.
- Default landing route: authorized direct push.
- Landing enforcement: procedural.
- Enforcement evidence: nothing blocks a push to `main`; the procedure is this page.
- Strengthened for: sensitive data — the service stores member addresses.

## Pre-commit feedback

None — no hooks are configured.

## Landing requirements

- **Verification suite**
  - Command: `make check`
  - Pass condition: exit 0 from a standalone clone.
  - Applies to: every change.
  - Evidence type: automated
  - Enforcement: procedural
  - Evidence state: available
  - CI status: none
- **Data-handling review** (strengthened for sensitive data)
  - Command: none
  - Pass condition: a second maintainer reads every change under `app/data/`.
  - Applies to: `app/data/`.
  - Evidence type: manual
  - Enforcement: procedural
  - Evidence state: available
  - CI status: none

### Docs-only surface

No docs-only surface is declared; every check is presumed to read every path.

## Release requirements

Not applicable — the service deploys from `main` without a versioned release.

## Deployment requirements

- **Production health**
  - Command: `bash scripts/health.sh`
  - Pass condition: exit 0 against the live endpoint after each deployment.
  - Applies to: every production deployment.
  - Evidence type: automated
  - Enforcement: procedural
  - Evidence state: available

## Known gaps

- No staging environment; deployment goes straight to production.
EOF
}

# make_fixture <dir> <profile>: a committed repository whose page and
# artifacts conform.
make_fixture() {
    local d="$1" profile="$2"
    git_init "$d"
    mkdir -p "$d/docs/work" "$d/scripts"
    "page_$profile" >"$d/docs/work/definition-of-done.md"
    case "$profile" in
        local | shared | production)
            printf '.PHONY: check lint\ncheck lint:\n\t@true\n' >"$d/Makefile"
            ;;
    esac
    case "$profile" in
        local) printf '#!/usr/bin/env bash\ntrue\n' >"$d/scripts/lint.sh" ;;
        production)
            printf '#!/usr/bin/env bash\ntrue\n' >"$d/scripts/health.sh"
            mkdir -p "$d/app/data"; echo x >"$d/app/data/README.md"
            echo "# Deploys" >"$d/docs/deploys.md"
            ;;
        shared)
            mkdir -p "$d/.github/workflows"
            printf 'on: push\njobs:\n  check:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make check\n' \
                >"$d/.github/workflows/check.yml"
            ;;
    esac
    echo "# Readme" >"$d/README.md"
    commit_all "$d"
}

FLAGS=()
# expect <label> <expected-exit> <profile> <mutate-fn|NONE> [required-substring]...
expect() {
    local label="$1" want="$2" profile="$3" fn="$4" sub
    shift 4
    local d="$TMP/case"
    rm -rf "$d"
    make_fixture "$d" "$profile"
    if [ "$fn" != NONE ]; then
        "$fn" "$d"
    fi
    local out rc=0 missing=0
    out=$(bash "$SCRIPT" "$d" ${FLAGS[@]+"${FLAGS[@]}"} 2>&1) || rc=$?
    if [ "$rc" -ne "$want" ]; then
        fail "$label: exit $rc, wanted $want"
        printf '%s\n' "$out" | sed 's/^/    /'
        return
    fi
    for sub in "$@"; do
        if ! printf '%s\n' "$out" | grep -Fq -- "$sub"; then
            echo "    missing: $sub"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        fail "$label: expected output text not found"
        printf '%s\n' "$out" | sed 's/^/    /'
        return
    fi
    ok "$label"
}

P=docs/work/definition-of-done.md

# --- usage errors ----------------------------------------------------------------
rc=0
out=$(bash "$SCRIPT" 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -Fq "usage: bash Tools/check-definition-of-done.sh"; then
    ok "missing argument is a usage error"
else
    fail "missing argument: exit $rc, wanted 2 with a usage line"
fi
mkdir -p "$TMP/plain"
rc=0
out=$(bash "$SCRIPT" "$TMP/plain" 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -Fq "not a Git worktree"; then
    ok "a non-Git root is a usage error"
else
    fail "non-Git root: exit $rc, wanted 2"
fi
make_fixture "$TMP/sub-root" local
rc=0
out=$(bash "$SCRIPT" "$TMP/sub-root/docs" 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -Fq "not the Git worktree root"; then
    ok "a subdirectory root is a usage error"
else
    fail "subdirectory root: exit $rc, wanted 2"
fi

# --- one conformant fixture per profile -------------------------------------------
for profile in scaffold local shared production; do
    expect "conformant $profile fixture" 0 "$profile" NONE \
        "ok   1" "ok   8" "ok   9" "definition of done: conformant"
done
FLAGS=(--conformant)
expect "a conformant page also passes under --conformant" 0 local NONE "definition of done: conformant"
FLAGS=()
expect "content-or-scaffold page with only None and Not applicable answers names no command" 0 scaffold NONE \
    "ok   8  no command to resolve"

# --- the page is required -----------------------------------------------------------
no_page() { git -C "$1" rm -q "$P"; }
expect "missing page" 1 local no_page "FAIL 0" "docs/work/definition-of-done.md is missing" "1 clause(s) failed"

# --- clause 1: heading and scope ----------------------------------------------------
no_scope() { replace "$1/$P" $'The evidence required before a change to this tool counts as done.\n' ''; }
expect "no scope statement" 1 local no_scope "FAIL 1" "no scope statement"

# --- clause 2: the six sections ------------------------------------------------------
for section in "Repository profile" "Pre-commit feedback" "Landing requirements" \
               "Release requirements" "Deployment requirements" "Known gaps"; do
    eval "drop_section() { replace \"\$1/\$P\" '## $section'\$'\\n' ''; }"
    expect "missing section: $section" 1 local drop_section "FAIL 2" "missing section \`## $section\`"
done
swap_sections() {
    replace "$1/$P" $'## Release requirements\n\nNot applicable — nothing is released or published.\n\n## Deployment requirements\n\nNot applicable — nothing is deployed.\n' \
        $'## Deployment requirements\n\nNot applicable — nothing is deployed.\n\n## Release requirements\n\nNot applicable — nothing is released or published.\n'
}
expect "sections out of order" 1 local swap_sections "FAIL 2" "sections out of order"
h2_first() { replace "$1/$P" '## Repository profile' $'## Overview\n\nAn extra section.\n\n## Repository profile'; }
expect "a level-two heading before the profile" 1 local h2_first "FAIL 2" "unexpected section \`## Overview\` before \`## Known gaps\`"
# One schema section in an otherwise older page does not make it schema-shaped:
# three fleet pages in the older shape carry `## Known gaps` or
# `## Landing requirements`.
old_with_gaps() {
    printf '# Definition of done\n\nThe evidence required.\n\n| Check | Command |\n|---|---|\n| Tests | make check |\n\n## Known gaps\n\n- none yet\n' >"$1/$P"
}
expect "an older page with one schema heading stays transitional" 0 local old_with_gaps "definition of done: transitional (older shape)"
h2_after() { printf '\n## See also\n\n- [schema](x.md)\n' >>"$1/$P"; }
expect "a further section after known gaps is allowed" 0 local h2_after "definition of done: conformant"

# --- clause 3: profile keys and values ------------------------------------------------
for key in "Declared unit" "Profile" "Production evidence" "Default landing route" \
           "Landing enforcement" "Enforcement evidence" "Strengthened for"; do
    eval "drop_key() { python3 - \"\$1/\$P\" '$key' <<'PY'
import re, sys
p, k = sys.argv[1], sys.argv[2]
t = open(p).read()
n = re.sub(r'(?m)^- ' + re.escape(k) + r':.*\n(?:  \S.*\n)*', '', t, count=1)
if n == t: sys.exit('key not found: ' + k)
open(p, 'w').write(n)
PY
}"
    eval "empty_key() { python3 - \"\$1/\$P\" '$key' <<'PY'
import re, sys
p, k = sys.argv[1], sys.argv[2]
t = open(p).read()
n = re.sub(r'(?m)^- ' + re.escape(k) + r':.*\n(?:  \S.*\n)*', '- ' + k + ':\n', t, count=1)
if n == t: sys.exit('key not found: ' + k)
open(p, 'w').write(n)
PY
}"
    expect "profile key missing: $key" 1 local drop_key "FAIL 3" "is missing the key \`$key:\`"
    expect "profile key empty: $key" 1 local empty_key "FAIL 3" "key \`$key:\` is empty"
done
keys_reordered() {
    replace "$1/$P" $'- Profile: [active local software](../../workshop/docs/verification-profiles.md#profiles).\n' ''
    replace "$1/$P" '- Strengthened for: none.' $'- Strengthened for: none.\n- Profile: active local software.'
}
expect "profile keys out of order" 1 local keys_reordered "FAIL 3" "keys out of order"
bad_profile() { replace "$1/$P" '- Profile: [active local software]' '- Profile: [hobby project]'; }
expect "unknown profile" 1 local bad_profile "FAIL 3" "Profile \`[hobby project]"
prod_na() { replace "$1/$P" $'- Production evidence: the maintainer operates https://service.example.test;\n  `docs/deploys.md` records every deployment.' '- Production evidence: Not applicable — production.'; }
expect "production profile without production evidence" 1 production prod_na "FAIL 3" "Production evidence \`Not applicable — production.\`"
prod_hyphen() { replace "$1/$P" 'Not applicable — active local software.' 'Not applicable - active local software.'; }
expect "production evidence with a hyphen for the em dash" 1 local prod_hyphen "FAIL 3" "must use an em dash"
bad_route() { replace "$1/$P" 'Default landing route: authorized direct push.' 'Default landing route: straight to main.'; }
expect "unknown landing route" 1 local bad_route "FAIL 3" "Default landing route \`straight to main.\`"
bad_le() { replace "$1/$P" 'Landing enforcement: procedural.' 'Landing enforcement: strict.'; }
expect "out-of-vocabulary landing enforcement" 1 local bad_le "FAIL 3" "Landing enforcement \`strict.\`"
unmarked_risk() { replace "$1/$P" '- **Data-handling review** (strengthened for sensitive data)' '- **Data-handling review**'; }
expect "a strengthened-for risk with no strengthened requirement" 1 production unmarked_risk "FAIL 3" "no requirement in sections 2-5 is marked as strengthened"

# --- clause 4: requirement grammar ------------------------------------------------------
bad_type() { replace "$1/$P" $'  - Evidence type: automated\n  - Enforcement: advisory' $'  - Evidence type: automated plus visual inspection\n  - Enforcement: advisory'; }
expect "out-of-vocabulary evidence type" 1 local bad_type "FAIL 4" "\`## Landing requirements\` requirement **Shell lint**: Evidence type \`automated plus visual inspection\`"
bad_enf() { replace "$1/$P" '  - Enforcement: advisory' '  - Enforcement: blocking'; }
expect "out-of-vocabulary enforcement" 1 local bad_enf "FAIL 4" "Enforcement \`blocking\` is not one of"
bad_state() { replace "$1/$P" $'  - Enforcement: advisory\n  - Evidence state: available' $'  - Enforcement: advisory\n  - Evidence state: available to maintainers'; }
expect "out-of-vocabulary evidence state" 1 local bad_state "FAIL 4" "Evidence state \`available to maintainers\`"
commands_label() { replace "$1/$P" '  - Command: `bash scripts/lint.sh`' '  - Commands: `bash scripts/lint.sh`'; }
expect "a Commands: label" 1 local commands_label "FAIL 4" "sub-line 1 is \`Commands:\` (an unknown label); expected \`Command:\`"
no_ci_status() { replace "$1/$P" $'  - Enforcement: advisory\n  - Evidence state: available\n  - CI status: none\n' $'  - Enforcement: advisory\n  - Evidence state: available\n'; }
expect "a landing requirement with no CI status" 1 local no_ci_status "FAIL 4" "**Shell lint**: missing \`CI status:\`"
release_ci() { replace "$1/$P" $'  - Applies to: every release tag.\n  - Evidence type: manual\n  - Enforcement: procedural\n  - Evidence state: available' $'  - Applies to: every release tag.\n  - Evidence type: manual\n  - Enforcement: procedural\n  - Evidence state: available\n  - CI status: none'; }
expect "CI status under release requirements" 1 shared release_ci "FAIL 4" "\`CI status\` belongs only under \`## Landing requirements\`"
na_bare() { replace "$1/$P" 'Not applicable — nothing is deployed.' 'N/A'; }
expect "a stage answered N/A" 1 local na_bare "FAIL 4" "\`## Deployment requirements\` opens with \`N/A\`"
stage_prose() { replace "$1/$P" 'None — no hooks or local checks are configured.' 'We sometimes run the linter by hand.'; }
expect "a stage holding prose with no requirement bullet" 1 local stage_prose "FAIL 4" "\`## Pre-commit feedback\` opens with \`We sometimes run"
none_hyphen() { replace "$1/$P" 'None — no hooks or local checks are configured.' 'None - no hooks.'; }
expect "a None line with a hyphen" 1 local none_hyphen "FAIL 4" "must use an em dash"
precommit_platform() {
    replace "$1/$P" 'None — no hooks or local checks are configured.' $'- **Formatter hook**\n  - Command: `make lint`\n  - Pass condition: exit 0.\n  - Applies to: every commit.\n  - Evidence type: automated\n  - Enforcement: platform-enforced\n  - Evidence state: available'
}
expect "platform-enforced under pre-commit feedback" 1 local precommit_platform "FAIL 4" "Enforcement \`platform-enforced\` is an error here"
extra_subline() { replace "$1/$P" $'  - CI status: none\n- **Shell lint**' $'  - CI status: none\n  - Runtime: about a minute.\n- **Shell lint**'; }
expect "a further sub-line after the fixed ones is allowed" 0 local extra_subline "definition of done: conformant"

# --- clause 5: profile enforcement summarizes landing --------------------------------
le_stronger() { replace "$1/$P" 'Landing enforcement: procedural.' 'Landing enforcement: platform-enforced.'; }
expect "landing enforcement stronger than the requirements" 1 production le_stronger "FAIL 5" "stronger than the strongest landing requirement, \`procedural\`"
le_none_platform() { replace "$1/$P" 'Landing enforcement: procedural.' 'Landing enforcement: platform-enforced.'; }
expect "platform-enforced landing with no landing requirements" 1 scaffold le_none_platform "FAIL 5" "with no landing requirement"

# --- clause 6: the platform-enforced citation ------------------------------------------
cite() { python3 - "$1/$P" "$2" <<'PY'
import re, sys
p, v = sys.argv[1], sys.argv[2]
t = open(p).read()
n = re.sub(r'(?m)^- Enforcement evidence:.*\n(?:  \S.*\n)*', '- Enforcement evidence: ' + v + '\n', t, count=1)
if n == t: sys.exit('Enforcement evidence not found')
open(p, 'w').write(n)
PY
}
cite_unconfirmed() { cite "$1" 'unconfirmed'; }
expect "platform-enforced with unconfirmed evidence" 1 shared cite_unconfirmed "FAIL 6" "Enforcement evidence is \`unconfirmed\`"
cite_undated() { cite "$1" 'ruleset seen through `gh api repos/example/lib/rulesets/1` by the maintainer.'; }
expect "platform-enforced with an undated citation" 1 shared cite_undated "FAIL 6" "no observation date"
cite_no_method() { cite "$1" 'the maintainer says main is protected, 2026-09-07.'; }
expect "platform-enforced with no observation method" 1 shared cite_no_method "FAIL 6" "names no observation method"
cite_url() { cite "$1" 'branch rule seen at https://github.com/example/lib/settings/rules on 2026-09-07 by the maintainer.'; }
expect "platform-enforced with a dated URL citation" 0 shared cite_url "ok   6" "definition of done: conformant"
prose_platform() { replace "$1/$P" '- No CI runs the suite; landing is procedural.' '- No CI runs the suite; nothing is platform-enforced.'; }
expect "platform-enforced in known-gaps prose declares nothing" 0 local prose_platform "no platform-enforced declaration"

# --- clause 7: the docs-only surface ------------------------------------------------------
no_dos() { replace "$1/$P" $'### Docs-only surface\n' ''; }
expect "no docs-only surface heading" 1 shared no_dos "FAIL 7" "no \`### Docs-only surface\` heading"
dos_both() { replace "$1/$P" $'<!-- DOCS-ONLY:END -->\n' $'<!-- DOCS-ONLY:END -->\n\nNo docs-only surface is declared.\n'; }
expect "both docs-only forms at once" 1 local dos_both "FAIL 7" "carries both"
dos_outside() {
    replace "$1/$P" $'<!-- DOCS-ONLY:BEGIN — paths no check in this repo reads. DO NOT REMOVE. -->\ndocs/\n<!-- DOCS-ONLY:END -->\n' 'No docs-only surface is declared.'
    printf '\n<!-- DOCS-ONLY:BEGIN -->\ndocs/\n<!-- DOCS-ONLY:END -->\n' >>"$1/$P"
}
expect "a sentinel block outside the docs-only section" 1 local dos_outside "FAIL 7" "sits outside \`### Docs-only surface\`"
dos_empty() { replace "$1/$P" 'No docs-only surface is declared; every check is presumed to read every path.' 'Docs are discussed elsewhere.'; }
expect "a docs-only section with neither form" 1 shared dos_empty "FAIL 7" "carries neither"
guidance_left() { replace "$1/$P" $'# Definition of done\n\nThe evidence' $'# Definition of done\n\n<!-- Scope statement, 1-3 sentences. -->\n\nThe evidence'; }
expect "a leftover guidance comment is ignored" 0 local guidance_left "definition of done: conformant"

# --- clause 9: known gaps -----------------------------------------------------------------
bare_gap() { replace "$1/$P" '- No CI runs the suite; landing is procedural.' '-'; }
expect "a bare - known gap" 1 local bare_gap "FAIL 9" "bare \`-\` bullet"
gap_prose() { replace "$1/$P" '- No CI runs the suite; landing is procedural.' 'Nothing much.'; }
expect "known gaps as prose" 1 local gap_prose "FAIL 9" "opens with \`Nothing much.\`"

# --- clause 8: command resolution reads the artifact ------------------------------------
missing_target() { replace "$1/$P" '  - Command: `make check`' '  - Command: `make verify`'; }
expect "a make target absent from the Makefile" 1 local missing_target "FAIL 8" "make target \`verify\` is not a rule in tracked Makefile"
add_target() { missing_target "$1"; printf 'verify:\n\t@true\n' >>"$1/Makefile"; git -C "$1" add Makefile; }
expect "the same page passes once the target exists" 0 local add_target "ok   8" "definition of done: conformant"
untracked_target() { missing_target "$1"; printf 'verify:\n\t@true\n' >>"$1/Makefile"; git -C "$1" rm -q --cached Makefile; }
expect "a target in an untracked Makefile does not resolve" 1 local untracked_target "FAIL 8" "no tracked Makefile at Makefile"
missing_script() { replace "$1/$P" 'bash scripts/lint.sh' 'bash scripts/check-style.sh'; }
expect "a script path that does not exist" 1 local missing_script "FAIL 8" "\`scripts/check-style.sh\` is not tracked"
untracked_script() { missing_script "$1"; printf 'true\n' >"$1/scripts/check-style.sh"; }
expect "a script on disk but not tracked" 1 local untracked_script "FAIL 8" "\`scripts/check-style.sh\` is not tracked"
tracked_script() { untracked_script "$1"; git -C "$1" add scripts/check-style.sh; }
expect "the same page passes once the script is tracked" 0 local tracked_script "definition of done: conformant"
bare_tool() { replace "$1/$P" 'bash scripts/lint.sh' 'uv run pytest'; }
expect "a bare tool invocation" 1 local bare_tool "FAIL 8" "Command \`uv run pytest\` names no repository artifact"
make_and_tool() { replace "$1/$P" 'bash scripts/lint.sh' 'make check && uv run pytest'; }
expect "make check && uv run pytest resolves on the make target" 0 local make_and_tool "definition of done: conformant"
cd_sub() {
    replace "$1/$P" 'bash scripts/lint.sh' 'cd sub && make check'
    mkdir -p "$1/sub"; printf 'check:\n\t@true\n' >"$1/sub/Makefile"; git -C "$1" add sub/Makefile
}
expect "cd sub && make check resolves against sub/Makefile" 0 local cd_sub "definition of done: conformant"
cd_sub_missing() {
    replace "$1/$P" 'bash scripts/lint.sh' 'cd sub && make test'
    mkdir -p "$1/sub"; printf 'check:\n\t@true\n' >"$1/sub/Makefile"; git -C "$1" add sub/Makefile
}
expect "cd sub && make test fails against sub/Makefile" 1 local cd_sub_missing "FAIL 8" "make target \`test\` is not a rule in tracked sub/Makefile"
npm_test() { replace "$1/$P" 'bash scripts/lint.sh' 'npm test'; }
expect "npm test with no workflow step" 1 local npm_test "FAIL 8" "Command \`npm test\` names no repository artifact"
npm_workflow() {
    npm_test "$1"
    mkdir -p "$1/.github/workflows"
    printf 'on: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - name: Test\n        run: npm test\n' >"$1/.github/workflows/test.yml"
    git -C "$1" add .github/workflows/test.yml
}
expect "npm test resolves as a tracked workflow step" 0 local npm_workflow "definition of done: conformant"
npm_untracked_workflow() { npm_workflow "$1"; git -C "$1" rm -q --cached .github/workflows/test.yml; }
expect "npm test in an untracked workflow does not resolve" 1 local npm_untracked_workflow "FAIL 8" "names no repository artifact"

# --- submodules: resolved inside when populated, unavailable when not --------------------
LIB="$TMP/lib-src"
git_init "$LIB"
mkdir -p "$LIB/tools"
printf '#!/usr/bin/env bash\ntrue\n' >"$LIB/tools/check.sh"
commit_all "$LIB"
with_submodule() {
    git -C "$1" -c protocol.file.allow=always submodule add -q "$LIB" lib
    git -C "$1" commit -qm "add lib"
    replace "$1/$P" 'bash scripts/lint.sh' 'bash lib/tools/check.sh'
}
expect "a path inside a populated submodule resolves inside it" 0 local with_submodule "definition of done: conformant"
submodule_missing_path() { with_submodule "$1"; replace "$1/$P" 'bash lib/tools/check.sh' 'bash lib/tools/gone.sh'; }
expect "a missing path inside a populated submodule fails" 1 local submodule_missing_path "FAIL 8" "\`lib/tools/gone.sh\` is not tracked"
submodule_uninit() { with_submodule "$1"; git -C "$1" submodule deinit -q -f lib; }
expect "a path inside an uninitialized submodule is unavailable" 0 local submodule_uninit \
    "unavailable lib/tools/check.sh — submodule lib is not initialized in this checkout" \
    "An unavailable is not a pass." "definition of done: incomplete — 1 artifact(s) unavailable"
FLAGS=(--conformant)
expect "--conformant turns unavailable into exit 1" 1 local submodule_uninit "definition of done: incomplete"
FLAGS=()

# --- the older single-table shape is transitional ----------------------------------------
old_shape() {
    printf '# Definition of done\n\nThe evidence required before a change lands.\n\n| Check | Command |\n|---|---|\n| Tests | make check |\n' >"$1/$P"
}
expect "an old-shape page is transitional" 0 local old_shape "ok   t" "definition of done: transitional (older shape)"
FLAGS=(--conformant)
expect "--conformant turns transitional into exit 1" 1 local old_shape "definition of done: transitional (older shape)"
FLAGS=()
heading_only() { printf '# Only a heading\n' >"$1/$P"; }
expect "a heading-only page fails" 1 local heading_only "FAIL t" "a heading and 0 line(s) of content"
no_heading() { printf 'just prose\nmore prose\n' >"$1/$P"; }
expect "a page with no level-one heading fails" 1 local no_heading "FAIL t" "no level-1 heading"

# --- the unfilled template must fail ------------------------------------------------------
unfilled() {
    python3 - "$TEMPLATE" >"$1/$P" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"<!--(?! DOCS-ONLY:).*?-->", "", text, flags=re.S)
sys.stdout.write(re.sub(r"\n{3,}", "\n\n", text))
PY
}
expect "the unfilled template fails" 1 local unfilled "FAIL 1" "FAIL 3" "key \`Profile:\` is empty" "FAIL 4" "FAIL 9" "clause(s) failed"

# --- the same verdict through a Workshop mount -------------------------------------------
# A plain copy of this checkout's tracked files, plus the checker itself in case
# it is not committed yet, is what a consumer's workshop/ mount holds.
CONSUMER="$TMP/consumer"
make_fixture "$CONSUMER" shared
mkdir -p "$CONSUMER/workshop"
(cd "$WORKSHOP_ROOT" && git ls-files -z | tar --null -T - -cf -) | tar -C "$CONSUMER/workshop" -xf -
mkdir -p "$CONSUMER/workshop/Tools"
cp "$SCRIPT" "$CONSUMER/workshop/Tools/check-definition-of-done.sh"
cp "$CONFORMANCE" "$CONSUMER/workshop/Tools/check-docs-work-conformance.sh"
rc=0
standalone=$(bash "$SCRIPT" "$CONSUMER" 2>&1) || rc=$?
rc_mount=0
mounted=$(cd "$CONSUMER" && bash workshop/Tools/check-definition-of-done.sh . 2>&1) || rc_mount=$?
v1=$(printf '%s\n' "$standalone" | grep '^definition of done: ' || true)
v2=$(printf '%s\n' "$mounted" | grep '^definition of done: ' || true)
if [ "$rc" -eq 0 ] && [ "$rc_mount" -eq 0 ] && [ "$v1" = "definition of done: conformant" ] && [ "$v1" = "$v2" ]; then
    ok "standalone and mounted runs reach the same verdict ($v2)"
else
    fail "standalone (exit $rc, '$v1') and mounted (exit $rc_mount, '$v2') runs differ"
    printf '%s\n' "$standalone" "---" "$mounted" | sed 's/^/    /'
fi
rc=0
out=$(cd "$CONSUMER" && bash workshop/Tools/check-docs-work-conformance.sh . 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -Eq '^ok +6 .*conforms to docs/definition-of-done-schema.md'; then
    ok "check-docs-work-conformance.sh delegates clause 6 through the mount"
else
    fail "conformance through the mount: exit $rc, wanted 0 with clause 6 conforming"
    printf '%s\n' "$out" | sed 's/^/    /'
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures assertion(s) failed" >&2
    exit 1
fi
echo "all check-definition-of-done assertions passed"
