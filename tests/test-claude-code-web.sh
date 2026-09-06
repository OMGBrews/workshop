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
    mkdir -p "$path/docs/work" "$path/.claude" "$path/scripts/agent"
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
    "setupScript": [
      "#!/bin/bash",
      "# project setup stub — v1. Real script: scripts/agent/cloud-setup.sh in the repo.",
      "# Bump the version above to force a cache rebuild after editing that script.",
      "set -euo pipefail",
      "bash /home/user/project/scripts/agent/cloud-setup.sh"
    ]
  }
}
```
<!-- WORKSHOP-CLOUD-SESSION:END -->
EOF
    printf '#!/bin/bash\n' >"$path/scripts/agent/cloud-setup.sh"
    chmod +x "$path/scripts/agent/cloud-setup.sh"
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

expected=$(printf '#!/bin/bash\n# project setup stub — v1. Real script: scripts/agent/cloud-setup.sh in the repo.\n# Bump the version above to force a cache rebuild after editing that script.\nset -euo pipefail\nbash /home/user/project/scripts/agent/cloud-setup.sh')
actual=$(python3 "$TOOL" render-setup "$case_dir")
[ "$actual" = "$expected" ] || fail "render-setup did not reproduce the exact line array"

case_dir="$TMP/blank-setup"
make_repo "$case_dir"
python3 - "$case_dir/docs/work/claude-code-web.md" <<'PY'
import json
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
start, payload = text.split("```json\n", 1)
payload, end = payload.split("\n```", 1)
data = json.loads(payload)
data["environment"]["setupScript"] = []
open(path, "w", encoding="utf-8").write(start + "```json\n" + json.dumps(data, indent=2) + "\n```" + end)
PY
actual=$(python3 "$TOOL" render-setup "$case_dir")
[ -z "$actual" ] || fail "an empty setupScript array did not render as a blank field"

case_dir="$TMP/relative-setup"
make_repo "$case_dir"
sed -i 's#bash /home/user/project/scripts/agent/cloud-setup.sh#bash scripts/agent/cloud-setup.sh#' "$case_dir/docs/work/claude-code-web.md"
expect_fail "relative setup path is rejected" "$case_dir" "expected the canonical five-line setup stub"

case_dir="$TMP/wrong-setup-repository"
make_repo "$case_dir"
sed -i 's#/home/user/project/#/home/user/other/#' "$case_dir/docs/work/claude-code-web.md"
expect_fail "wrong setup repository is rejected" "$case_dir" "expected the canonical five-line setup stub"

case_dir="$TMP/missing-setup-script"
make_repo "$case_dir"
rm "$case_dir/scripts/agent/cloud-setup.sh"
expect_fail "missing setup script is rejected" "$case_dir" "must exist and be executable"

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

# --- Standard bootstrap-kit adoption -----------------------------------------
#
# A repository can carry correct, committed agent surfaces that resolve only
# through its Workshop mount while nothing in it is able to bootstrap that
# mount — and the only symptom is that the shared skills are silently missing
# when someone opens a cloud session. Each case below damages exactly one
# adoption edge and asserts the validator names the repository, the edge, and
# the remedy. `make_consumer` starts from the same declaration the cases above
# use, so a failure here is about the kit and nothing else.

TEMPLATES="$ROOT/docs/templates/cloud-sessions"

# The command `.claude/settings.json` records verbatim. $CLAUDE_PROJECT_DIR is
# expanded by Claude Code when it runs the hook, never by this shell.
# shellcheck disable=SC2016
WRAPPER_COMMAND='"$CLAUDE_PROJECT_DIR"/.claude/hooks/session-start.sh'

# <path> [workshop-url]
make_consumer() {
    local path="$1" url="${2:-https://github.com/OMGBrews/workshop.git}"
    make_repo "$path"
    cat >"$path/.gitmodules" <<EOF
[submodule "workshop"]
	path = workshop
	url = $url
EOF
    mkdir -p "$path/workshop/docs/templates/cloud-sessions" "$path/.claude/hooks"
    cp "$TEMPLATES/agent-session-start.sh" "$path/workshop/docs/templates/cloud-sessions/"
    cp "$TEMPLATES/session-start.sh" "$path/workshop/docs/templates/cloud-sessions/"
    cp "$TEMPLATES/agent-session-start.sh" "$path/scripts/agent/session-start.sh"
    cp "$TEMPLATES/session-start.sh" "$path/.claude/hooks/session-start.sh"
    chmod +x "$path/scripts/agent/session-start.sh" "$path/.claude/hooks/session-start.sh"
    write_settings "$path" "$WRAPPER_COMMAND" command 120
}

# <path> <command> <type-json-fragment> <timeout-json-fragment>
# type and timeout are written raw so a case can omit or mistype either.
write_settings() {
    local path="$1" command="$2" type="$3" timeout="$4"
    python3 - "$path/.claude/settings.json" "$command" "$type" "$timeout" <<'PY'
import json, sys
path, command, type_value, timeout_value = sys.argv[1:5]
hook = {"command": command}
if type_value != "-":
    hook["type"] = type_value
if timeout_value != "-":
    hook["timeout"] = int(timeout_value)
data = {
    "permissions": {"allow": []},
    "remote": {"defaultEnvironmentId": "env_abc123"},
    "hooks": {"SessionStart": [{"hooks": [hook]}]},
}
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
}

case_dir="$TMP/kit-complete"
make_consumer "$case_dir"
expect_pass "complete standard kit" "$case_dir"

# The legacy redirecting URL is the spelling most of the fleet still records.
# If normalization ever exempted it, every one of those repositories would drop
# out of this rule with nothing printed to say so.
case_dir="$TMP/kit-legacy-url-complete"
make_consumer "$case_dir" "https://github.com/OMGBrewmaster/workshop.git"
expect_pass "legacy Workshop URL is still a consumer" "$case_dir"

case_dir="$TMP/kit-legacy-url-damaged"
make_consumer "$case_dir" "https://github.com/OMGBrewmaster/workshop.git"
rm "$case_dir/scripts/agent/session-start.sh"
expect_fail "legacy Workshop URL cannot evade the kit rule" "$case_dir" \
    "scripts/agent/session-start.sh is absent"

case_dir="$TMP/kit-ssh-url"
make_consumer "$case_dir" "git@github.com:OMGBrews/workshop.git"
rm "$case_dir/.claude/hooks/session-start.sh"
expect_fail "ssh Workshop URL cannot evade the kit rule" "$case_dir" \
    ".claude/hooks/session-start.sh is absent"

case_dir="$TMP/kit-missing-neutral"
make_consumer "$case_dir"
rm "$case_dir/scripts/agent/session-start.sh"
expect_fail "missing neutral bootstrap" "$case_dir" \
    "Fix: cp workshop/docs/templates/cloud-sessions/agent-session-start.sh scripts/agent/session-start.sh"

case_dir="$TMP/kit-missing-wrapper"
make_consumer "$case_dir"
rm "$case_dir/.claude/hooks/session-start.sh"
expect_fail "missing Claude wrapper" "$case_dir" \
    "Fix: cp workshop/docs/templates/cloud-sessions/session-start.sh .claude/hooks/session-start.sh"

case_dir="$TMP/kit-not-executable"
make_consumer "$case_dir"
chmod -x "$case_dir/scripts/agent/session-start.sh"
expect_fail "non-executable deployed copy" "$case_dir" \
    "is not executable, so the session bootstrap cannot run. Fix: chmod +x scripts/agent/session-start.sh"

case_dir="$TMP/kit-wrapper-not-executable"
make_consumer "$case_dir"
chmod -x "$case_dir/.claude/hooks/session-start.sh"
expect_fail "non-executable wrapper" "$case_dir" \
    "chmod +x .claude/hooks/session-start.sh"

case_dir="$TMP/kit-drift"
make_consumer "$case_dir"
printf '# local hotfix\n' >>"$case_dir/scripts/agent/session-start.sh"
expect_fail "deployed copy drifted from its template" "$case_dir" \
    "differs from its canonical template workshop/docs/templates/cloud-sessions/agent-session-start.sh"

case_dir="$TMP/kit-wrapper-drift"
make_consumer "$case_dir"
printf '# local hotfix\n' >>"$case_dir/.claude/hooks/session-start.sh"
expect_fail "wrapper drifted from its template" "$case_dir" \
    "differs from its canonical template workshop/docs/templates/cloud-sessions/session-start.sh"

# The incident shape: committed agent surfaces pointing into a mount that
# nothing populated. The mount is read from .gitmodules, not from a resolved
# symlink, precisely so this stays visible.
case_dir="$TMP/kit-uninitialized-mount"
make_consumer "$case_dir"
rm -rf "$case_dir/workshop"
expect_fail "uninitialized Workshop mount" "$case_dir" \
    "not initialized (workshop/docs/templates/cloud-sessions/agent-session-start.sh is absent)"

case_dir="$TMP/kit-no-registration"
make_consumer "$case_dir"
cat >"$case_dir/.claude/settings.json" <<'EOF'
{"permissions":{"allow":[]},"remote":{"defaultEnvironmentId":"env_abc123"}}
EOF
expect_fail "wrapper deployed but never registered" "$case_dir" \
    "registers no SessionStart hook running the standard bootstrap wrapper"

case_dir="$TMP/kit-wrong-hook-type"
make_consumer "$case_dir"
write_settings "$case_dir" "$WRAPPER_COMMAND" prompt 120
expect_fail "registration with the wrong command type" "$case_dir" \
    "with type 'prompt'; the canonical hook object declares type \"command\""

case_dir="$TMP/kit-missing-hook-type"
make_consumer "$case_dir"
write_settings "$case_dir" "$WRAPPER_COMMAND" - 120
expect_fail "registration with no command type" "$case_dir" \
    "the canonical hook object declares type \"command\""

case_dir="$TMP/kit-wrong-timeout"
make_consumer "$case_dir"
write_settings "$case_dir" "$WRAPPER_COMMAND" command 600
expect_fail "registration with the wrong timeout" "$case_dir" \
    "with timeout 600; the canonical hook object declares timeout 120"

case_dir="$TMP/kit-missing-timeout"
make_consumer "$case_dir"
write_settings "$case_dir" "$WRAPPER_COMMAND" command -
expect_fail "registration with no timeout" "$case_dir" \
    "the canonical hook object declares timeout 120"

# Standard adoption constrains the Workshop bootstrap entry and nothing else:
# a project keeping its own SessionStart hook alongside is conforming.
case_dir="$TMP/kit-extra-project-hook"
make_consumer "$case_dir"
python3 - "$case_dir/.claude/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data["hooks"]["SessionStart"].append(
    {"hooks": [{"type": "command", "command": "bash scripts/project-hook.sh", "timeout": 600}]}
)
data["hooks"]["PreToolUse"] = [{"matcher": "Bash", "hooks": [{"type": "command", "command": "true"}]}]
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
expect_pass "project-specific hooks are preserved alongside the standard hook" "$case_dir"

# A submodule that is not Workshop says nothing about the kit.
case_dir="$TMP/kit-unrelated-submodule"
make_repo "$case_dir"
cat >"$case_dir/.gitmodules" <<'EOF'
[submodule "library"]
	path = library
	url = https://github.com/example/library.git
EOF
expect_pass "a non-Workshop submodule requires no kit" "$case_dir"

# The opt-outs are the declared negative states, and only those. An absent or
# malformed declaration stays a failure: silence is not an answer.
kit_absent() {
    rm -f "$1/scripts/agent/session-start.sh" "$1/.claude/hooks/session-start.sh"
    cat >"$1/.claude/settings.json" <<'EOF'
{"permissions":{"allow":[]}}
EOF
}

declare_negative() { # <path> <availability>
    cat >"$1/docs/work/claude-code-web.md" <<EOF
# Claude Code Web

<!-- WORKSHOP-CLOUD-SESSION:BEGIN -->
\`\`\`json
{
  "version": 1,
  "availability": "$2",
  "primaryRepository": "example/project",
  "additionalRepositories": [],
  "reason": "fixture"
}
\`\`\`
<!-- WORKSHOP-CLOUD-SESSION:END -->
EOF
}

case_dir="$TMP/kit-opt-out-not-configured"
make_consumer "$case_dir"
kit_absent "$case_dir"
declare_negative "$case_dir" not-configured
expect_pass "not-configured opts out of the kit requirement" "$case_dir"

case_dir="$TMP/kit-opt-out-unsupported"
make_consumer "$case_dir"
kit_absent "$case_dir"
declare_negative "$case_dir" unsupported
expect_pass "unsupported opts out of the kit requirement" "$case_dir"

case_dir="$TMP/kit-absent-declaration"
make_consumer "$case_dir"
kit_absent "$case_dir"
rm "$case_dir/docs/work/claude-code-web.md"
expect_fail "an absent declaration is not an opt-out" "$case_dir" "missing declaration"

case_dir="$TMP/kit-malformed-declaration"
make_consumer "$case_dir"
kit_absent "$case_dir"
sed -i 's/"availability": "configured"/"availability": "someday"/' \
    "$case_dir/docs/work/claude-code-web.md"
expect_fail "a malformed declaration is not an opt-out" "$case_dir" \
    "configuration.availability: expected configured, not-configured, or unsupported"

if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)" >&2
    exit 1
fi
echo "all Claude Code Web declaration tests passed"
