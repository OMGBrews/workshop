#!/usr/bin/env bash
# Regression tests for the repository-owned Claude Code Web declaration tool.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/Tools/claude-code-web.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

make_repo() {
    local path="$1"
    mkdir -p "$path/docs/work" "$path/.claude"
    git init -q "$path"
    git -C "$path" remote add origin https://github.com/example/project.git
    cat >"$path/docs/work/claude-code-web.md" <<'EOF'
# Claude Code Web

Fixture declaration.

<!-- WORKSHOP-CLOUD-SESSION:BEGIN -->
```json
{
  "version": 1,
  "availability": "configured",
  "primaryRepository": "example/project",
  "additionalRepositories": ["example/dependency"],
  "environment": {
    "name": "project-cloud",
    "id": "env_abc123",
    "network": {
      "access": "custom",
      "includeCommonPackageManagers": true,
      "allowedDomains": ["*.example.org", "api.example.com"]
    },
    "environmentVariables": [
      {"name": "API_TOKEN", "source": "secret", "required": true},
      {"name": "FEATURE_MODE", "source": "literal", "value": "enabled"}
    ],
    "setupScript": ["#!/usr/bin/env bash", "set -euo pipefail", "bash scripts/setup.sh"]
  }
}
```
<!-- WORKSHOP-CLOUD-SESSION:END -->
EOF
    cat >"$path/.claude/settings.json" <<'EOF'
{"permissions":{"allow":[]},"remote":{"defaultEnvironmentId":"env_abc123"}}
EOF
}

expect_pass() {
    local label="$1" path="$2" output rc=0
    output=$(python3 "$TOOL" validate "$path" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$label: exit $rc"
        printf '%s\n' "$output" | sed 's/^/    /'
    else
        echo "ok: $label"
    fi
}

expect_fail() {
    local label="$1" path="$2" expected="$3" output rc=0
    output=$(python3 "$TOOL" validate "$path" 2>&1) || rc=$?
    if [ "$rc" -ne 1 ]; then
        fail "$label: exit $rc, wanted 1"
    elif ! printf '%s\n' "$output" | grep -Fq "$expected"; then
        fail "$label: missing diagnostic: $expected"
        printf '%s\n' "$output" | sed 's/^/    /'
    else
        echo "ok: $label"
    fi
}

case_dir="$TMP/valid"
make_repo "$case_dir"
expect_pass "complete configured declaration" "$case_dir"

output=$(python3 "$TOOL" show "$case_dir")
printf '%s\n' "$output" | grep -Fq "Environment: project-cloud" || fail "show omits environment"
printf '%s\n' "$output" | grep -Fq "Environment variables: API_TOKEN, FEATURE_MODE" \
    || fail "show omits variable names"
if printf '%s\n' "$output" | grep -Fq "enabled"; then
    fail "show prints literal values instead of a safe summary"
fi

output=$(python3 "$TOOL" show "$case_dir" --json)
printf '%s\n' "$output" | python3 -m json.tool >/dev/null || fail "show --json is not valid JSON"
first_key=$(printf '%s\n' "$output" | sed -n '2s/^[[:space:]]*"\([^"]*\)".*/\1/p')
[ "$first_key" = "additionalRepositories" ] || fail "show --json does not sort keys"

expected=$(printf '#!/usr/bin/env bash\nset -euo pipefail\nbash scripts/setup.sh')
actual=$(python3 "$TOOL" render-setup "$case_dir")
[ "$actual" = "$expected" ] || fail "render-setup did not reproduce the exact line array"

case_dir="$TMP/blank-setup"
make_repo "$case_dir"
sed -i 's/\["#!\/usr\/bin\/env bash", "set -euo pipefail", "bash scripts\/setup.sh"\]/[]/' \
    "$case_dir/docs/work/claude-code-web.md"
actual=$(python3 "$TOOL" render-setup "$case_dir")
[ -z "$actual" ] || fail "an empty setupScript array did not render as a blank field"

case_dir="$TMP/mismatch"
make_repo "$case_dir"
sed -i 's/env_abc123/env_other/' "$case_dir/.claude/settings.json"
expect_fail "settings ID mismatch" "$case_dir" "does not match environment.id"

case_dir="$TMP/no-settings"
make_repo "$case_dir"
rm "$case_dir/.claude/settings.json"
expect_fail "configured declaration without settings" "$case_dir" "must declare remote.defaultEnvironmentId"

case_dir="$TMP/secret-value"
make_repo "$case_dir"
sed -i 's/"required": true/"required": true, "value": "leak"/' "$case_dir/docs/work/claude-code-web.md"
expect_fail "secret value is forbidden" "$case_dir" "unexpected key(s): value"

case_dir="$TMP/secret-literal"
make_repo "$case_dir"
sed -i 's/"FEATURE_MODE"/"OPENROUTER_API_KEY"/' "$case_dir/docs/work/claude-code-web.md"
expect_fail "secret-bearing name cannot be literal" "$case_dir" "cannot use source literal"

case_dir="$TMP/public-key-literal"
make_repo "$case_dir"
sed -i 's/{"name": "FEATURE_MODE", "source": "literal", "value": "enabled"}/{"name": "PUBLIC_API_KEY", "source": "literal", "value": "public-id", "nonSecretJustification": "Provider documentation identifies this browser value as public."}/' \
    "$case_dir/docs/work/claude-code-web.md"
expect_pass "known public value can justify a secret-like name" "$case_dir"

case_dir="$TMP/unsorted-domains"
make_repo "$case_dir"
sed -i 's/"\*.example.org", "api.example.com"/"api.example.com", "*.example.org"/' "$case_dir/docs/work/claude-code-web.md"
expect_fail "domains must be deterministic" "$case_dir" "entries must be sorted"

case_dir="$TMP/duplicate-variable"
make_repo "$case_dir"
sed -i '0,/"API_TOKEN"/s//"FEATURE_MODE"/' "$case_dir/docs/work/claude-code-web.md"
expect_fail "variable names are unique" "$case_dir" "names must be unique"

case_dir="$TMP/duplicate-key"
make_repo "$case_dir"
sed -i '/"version": 1,/a\  "version": 1,' "$case_dir/docs/work/claude-code-web.md"
expect_fail "duplicate JSON keys are rejected" "$case_dir" "duplicate JSON key: version"

case_dir="$TMP/missing-sentinel"
make_repo "$case_dir"
sed -i '/WORKSHOP-CLOUD-SESSION:END/d' "$case_dir/docs/work/claude-code-web.md"
expect_fail "missing sentinel" "$case_dir" "expected exactly one"

case_dir="$TMP/origin-mismatch"
make_repo "$case_dir"
git -C "$case_dir" remote set-url origin https://github.com/example/other.git
expect_fail "primary repository must match origin" "$case_dir" "does not match the checkout origin"

case_dir="$TMP/not-configured"
mkdir -p "$case_dir/docs/work"
git init -q "$case_dir"
git -C "$case_dir" remote add origin https://github.com/example/project.git
cat >"$case_dir/docs/work/claude-code-web.md" <<'EOF'
# Claude Code Web

<!-- WORKSHOP-CLOUD-SESSION:BEGIN -->
```json
{
  "version": 1,
  "availability": "not-configured",
  "primaryRepository": "example/project",
  "additionalRepositories": [],
  "reason": "No environment has been provisioned."
}
```
<!-- WORKSHOP-CLOUD-SESSION:END -->
EOF
expect_pass "explicit not-configured state" "$case_dir"
output=$(python3 "$TOOL" show "$case_dir")
printf '%s\n' "$output" | grep -Fq "Reason: No environment has been provisioned." \
    || fail "show omits not-configured reason"
rc=0
output=$(python3 "$TOOL" render-setup "$case_dir" 2>&1) || rc=$?
[ "$rc" -eq 1 ] || fail "render-setup accepts a not-configured declaration"
printf '%s\n' "$output" | grep -Fq "cannot render" || fail "render-setup lacks refusal diagnostic"

mkdir -p "$case_dir/.claude"
printf '{"remote":{"defaultEnvironmentId":"env_stale"}}\n' >"$case_dir/.claude/settings.json"
expect_fail "not-configured state rejects stale default" "$case_dir" "contradicts availability"

case_dir="$TMP/unsupported"
mkdir -p "$case_dir/docs/work"
git init -q "$case_dir"
git -C "$case_dir" remote add origin https://github.com/example/project.git
cat >"$case_dir/docs/work/claude-code-web.md" <<'EOF'
# Claude Code Web

<!-- WORKSHOP-CLOUD-SESSION:BEGIN -->
```json
{
  "version": 1,
  "availability": "unsupported",
  "primaryRepository": "example/project",
  "additionalRepositories": [],
  "reason": "The required platform is unavailable in cloud sessions."
}
```
<!-- WORKSHOP-CLOUD-SESSION:END -->
EOF
expect_pass "explicit unsupported state" "$case_dir"

rc=0
output=$(python3 "$TOOL" validate "$ROOT" 2>&1) || rc=$?
[ "$rc" -eq 1 ] || fail "public Workshop host unexpectedly validates as a session primary"
printf '%s\n' "$output" | grep -Fq "missing declaration" \
    || fail "Workshop host exception lacks the expected missing-declaration result"

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)" >&2
    exit 1
fi
echo "all Claude Code Web declaration tests passed"
