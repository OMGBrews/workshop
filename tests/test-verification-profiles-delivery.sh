#!/usr/bin/env bash
# Regression test for navigation between the canonical profile guidance and
# its reader-side classification fixture. Each negative control proves the
# corresponding positive assertion can observe a missing edge.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

check_profile_links() {
    local profiles=$1
    local fixture=$2
    grep -qF 'verification-profiles-classification-fixture.md' "$profiles" \
        && grep -qF 'verification-profiles.md' "$fixture"
}

echo "== profile fixture navigation"
profiles="$ROOT/docs/verification-profiles.md"
fixture="$ROOT/docs/verification-profiles-classification-fixture.md"
if check_profile_links "$profiles" "$fixture"; then
    echo "ok - canonical profile document and fixture link to each other"
else
    fail "canonical profile document and fixture do not link to each other"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
grep -v 'verification-profiles-classification-fixture.md' "$profiles" \
    > "$tmp/profiles-without-fixture.md"
if check_profile_links "$tmp/profiles-without-fixture.md" "$fixture"; then
    fail "negative control passed after the fixture link was removed"
else
    echo "ok - removing the fixture link makes the assertion fail"
fi

grep -v 'verification-profiles.md' "$fixture" \
    > "$tmp/fixture-without-profiles.md"
if check_profile_links "$profiles" "$tmp/fixture-without-profiles.md"; then
    fail "negative control passed after the canonical-document link was removed"
else
    echo "ok - removing the canonical-document link makes the assertion fail"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures verification-profile delivery assertion(s) failed" >&2
    exit 1
fi
echo "all verification-profile delivery assertions passed"

