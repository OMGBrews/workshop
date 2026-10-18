#!/usr/bin/env bash
# Regression tests for the ship skill's dependency-ordering rules. Each required
# sentence is asserted verbatim, and a copy of the skill with that sentence
# stripped must fail the same assertion; otherwise a pass would not prove the
# rule is present.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/.agents/skills/ship/SKILL.md"
failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

rules=(
    "precedence|**An owning repository's documented ordering overrides this skill's parent-PR timing.**"
    "exact artifact|**Run a parent's checks against the gitlinks its candidate commit records.**"
    "deferred parent|**A parent whose checks pass only against an unmerged child is a dependent parent: push its branch, but do not open its PR.**"
    "deferred parent opens after the child merges|**A deferred parent opens here.**"
    "do-NOT entry|**Do NOT open a parent PR whose checks cannot pass against its recorded gitlinks.**"
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== ship dependency-ordering rules"
for entry in "${rules[@]}"; do
    label="${entry%%|*}"
    sentence="${entry#*|}"
    if grep -qF -- "$sentence" "$SKILL"; then
        echo "ok - ship states the $label rule"
    else
        fail "ship SKILL.md lacks the $label rule: $sentence"
        continue
    fi
    grep -vF -- "$sentence" "$SKILL" > "$tmp/stripped.md" || true
    if grep -qF -- "$sentence" "$tmp/stripped.md"; then
        fail "negative control passed after the $label rule was removed"
    else
        echo "ok - removing the $label rule makes the assertion fail"
    fi
done

echo "== retired open-everything wording"
if grep -qF 'temporarily incomplete' "$SKILL"; then
    fail "ship SKILL.md still permits a temporarily incomplete parent PR"
else
    echo "ok - the temporarily-incomplete parent PR is gone"
fi

echo "== kit template agrees"
template="$ROOT/docs/templates/cloud-sessions/cloud-sessions-rule.md"
if grep -qF 'defers a parent whose checks depend on an unmerged child' "$template"; then
    echo "ok - kit template names the deferred parent"
else
    fail "cloud-sessions kit template does not say dependent parents are deferred"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures ship-skill rule assertion(s) failed" >&2
    exit 1
fi
echo "all ship-skill rule assertions passed"
