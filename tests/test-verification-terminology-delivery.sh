#!/usr/bin/env bash
# Regression tests for the standing terminology rule and late-bootstrap
# recovery template. A missing line must make the assertion fail; otherwise the
# positive result would not prove that sessions can receive the document.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

check_cloud_recovery() {
    local file=$1
    grep -qF '<MOUNT>/docs/signal-hygiene.md' "$file" \
        && grep -qF '<MOUNT>/docs/definition-of-done.md' "$file" \
        && grep -qF '<MOUNT>/docs/verification-terminology.md' "$file"
}

echo "== standing terminology delivery"
grep -qF '@docs/verification-terminology.md' "$ROOT/CLAUDE.md" \
    || fail "Workshop CLAUDE.md does not eagerly import the terminology"
grep -qF '](docs/verification-terminology.md)' "$ROOT/AGENTS.md" \
    || fail "Workshop AGENTS.md does not plainly link the terminology"
echo "ok - Workshop exposes both instruction paths"

echo "== late-bootstrap recovery"
template="$ROOT/docs/templates/cloud-sessions/claude-md-cloud-section.md"
if check_cloud_recovery "$template"; then
    echo "ok - cloud template names all three manual recovery reads"
else
    fail "cloud template does not recover all three standing rules"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
grep -v 'verification-terminology.md' "$template" > "$tmp/missing-terminology.md"
if check_cloud_recovery "$tmp/missing-terminology.md"; then
    fail "negative control passed after terminology recovery was removed"
else
    echo "ok - removing terminology recovery makes the assertion fail"
fi

echo "== fixture navigation"
grep -qF 'verification-terminology-classification-fixture.md' \
    "$ROOT/docs/verification-terminology.md" \
    || fail "canonical terminology does not link the classification fixture"
grep -qF 'verification-terminology.md' \
    "$ROOT/docs/verification-terminology-classification-fixture.md" \
    || fail "classification fixture does not link the canonical terminology"
echo "ok - canonical document and fixture link to each other"

if [ "$failures" -ne 0 ]; then
    echo "$failures verification-terminology delivery assertion(s) failed" >&2
    exit 1
fi
echo "all verification-terminology delivery assertions passed"
