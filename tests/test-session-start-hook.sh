#!/usr/bin/env bash
# Tests for the cloud-sessions kit session bootstrap — BOTH halves:
#   docs/templates/cloud-sessions/agent-session-start.sh  (neutral, deployed to
#                                                          scripts/agent/session-start.sh)
#   docs/templates/cloud-sessions/session-start.sh        (Claude Code wrapper,
#                                                          deployed to .claude/hooks/)
#
# Nearly every case below drives the pair through the wrapper, because that is
# how a Claude Code session reaches it and the JSON envelope is what the
# assertions read. Cases 12 and 13 are the split's own contract: the neutral
# script must work as a plain command with no harness at all, and the wrapper
# must be loud rather than silent when the neutral script is missing.
#
# The bootstrap's contract, asserted here:
#   1. initializes each uninitialized submodule, independently per submodule;
#   2. tolerates one submodule failing to initialize and still initializes the
#      rest (the batch --init --recursive abort is the bug the hook exists to
#      avoid — observed 2026-07-16, llmkit-dev);
#   3. never touches an initialized submodule (no yank back to the recorded
#      pointer mid-task);
#   4. drift guard: warns when the deployed copy differs from the template,
#      and stays silent when they are byte-identical — both directions, so the
#      silent case cannot false-pass via a guard that never ran;
#   5. exits 0, silently, in a repo with no submodules;
#   6. freshness: fetches origin (pruning tracking refs whose remote branch
#      is gone, restoring a missing origin/HEAD) and reports where the local
#      default branch stands — up to date, or N behind — without moving a
#      ref outside a cloud session (report only), loudly on a failed fetch,
#      and silently when there is no origin (folded into 5, whose fixture
#      has none);
#   7. cloud auto-sync: with CLAUDE_CODE_REMOTE=true, a clean tree, and no
#      local commits, the working branch fast-forwards to the remote default
#      branch, the local default branch ref is carried along, and initialized
#      submodules re-sync to the moved pointers — and the fast-forward is
#      withheld when the branch carries its own commits or the tree is dirty.
#   8. private-submodule token fallback: a token init that FAILS (the fetch is
#      blocked) leaves the empty submodule worktree without repointing the
#      SUPERPROJECT's origin — the `git -C <path> remote set-url` cleanup is
#      guarded on that worktree actually being a repo, so `git -C` cannot walk
#      up to the enclosing superproject and repoint it (regression observed in
#      found-in-words-cms's first cloud session, 2026-07-19).
#   9. transient-fetch retry: a fetch that fails once (the proxy-credential race
#      at container startup) then succeeds is retried through to the freshness
#      report, not reported as a hard failure — a single miss no longer strands
#      the checkout at snapshot age for the session (found-in-words-cms,
#      2026-07-24).
#  10. parent-side pointer check: for each DECLARED edge (`branch = main`) the
#      recorded gitlink is compared against the child's remote tip and a
#      difference is reported with both SHAs; an in-sync edge is silent, a
#      PINNED edge whose remote has also moved stays silent by design, and an
#      unreachable child is reported as unchecked rather than skipped quietly.
#      Every other path the block implements is asserted too: a declared branch
#      the child's remote does not carry, and a declared entry HEAD records no
#      gitlink for, are both reported as unchecked; and the remote tip is read
#      only from a real advertisement of the requested ref, so a warning git
#      writes to stderr on a SUCCESSFUL ls-remote cannot be mistaken for a SHA
#      and turned into a confident false lag report.
#  11. JSON output contract: stdout is a single JSON object carrying the report
#      in hookSpecificOutput.additionalContext, and reloadSkills EXACTLY when
#      this run initialized or re-synced a submodule — the request that makes
#      a freshly-initialized skills submodule invocable as slash commands
#      instead of merely readable (found-in-words-cms, 2026-07-29). The
#      no-change run asserting reloadSkills ABSENT is the load-bearing half:
#      an unconditional `"reloadSkills":true` satisfies the positive case
#      trivially. Silence stays byte-empty, and report text containing JSON
#      metacharacters survives escaping intact.
#  12. harness independence: the neutral script run as a plain command, with no
#      wrapper and no CLAUDE_* variable in the environment, does the same work
#      and prints the same report as ordinary lines — not JSON. This is the
#      whole point of the split, so it is asserted directly rather than inferred
#      from the wrapper passing.
#  13. a missing neutral script is REPORTED, not silently skipped. The wrapper
#      firing while the bootstrap is absent is the one failure mode the split
#      introduces, and its symptom — a stale checkout with uninitialized
#      submodules — is indistinguishable from a healthy session unless the
#      wrapper says so (signal-hygiene.md).
set -euo pipefail

DEVTOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_TEMPLATE="$DEVTOOLS_ROOT/docs/templates/cloud-sessions/session-start.sh"
NEUTRAL_TEMPLATE="$DEVTOOLS_ROOT/docs/templates/cloud-sessions/agent-session-start.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic git: ignore the user's and system's config; allow file:// submodule
# URLs (blocked by default since git 2.38.1) for these fixtures only.
export HOME="$TMP/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
git config --global user.email test@example.invalid
git config --global user.name "hook test"
git config --global protocol.file.allow always
git config --global init.defaultBranch main
unset CLAUDE_CODE_REMOTE SUBMODULE_READ_TOKEN || true

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- reading the hook's JSON output ----------------------------------------
# The hook emits one JSON object (see its "Output contract" header), so the
# report lines the assertions below grep for live inside a single escaped
# string. Grepping that raw line would quietly cost every `grep A | grep B`
# its "same line" meaning, so the report is decoded back to real lines first
# and the existing assertions keep exactly the semantics they were written
# with. Needs a JSON reader: jq (this devcontainer) or python3 (CI). Neither
# present is a hard failure, never a silent skip.
JSONTOOL=""
if command -v jq >/dev/null 2>&1; then JSONTOOL=jq
elif command -v python3 >/dev/null 2>&1; then JSONTOOL=python3
else fail "these tests need jq or python3 to read the hook's JSON output; neither is on PATH"
fi

json_valid() { # raw JSON on stdin
  case "$JSONTOOL" in
    jq) jq -e . >/dev/null 2>&1 ;;
    python3) python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 ;;
  esac
}

json_get() { # <field-of-hookSpecificOutput>; raw JSON on stdin; "" when absent
  case "$JSONTOOL" in
    jq) jq -r --arg f "$1" '.hookSpecificOutput[$f] // ""' ;;
    python3) python3 -c 'import json,sys
v = json.load(sys.stdin).get("hookSpecificOutput", {}).get(sys.argv[1], "")
print("true" if v is True else "false" if v is False else v)' "$1" ;;
  esac
}

decode_report() { # <raw-stdout> -> the human-readable report, real newlines
  [ -n "$1" ] || return 0                    # silence decodes to silence
  printf '%s' "$1" | json_valid || fail "hook stdout is not valid JSON: $1"
  printf '%s' "$1" | json_get additionalContext
}

make_src_repo() { # <path> — a repo usable as a file:// submodule source
  git init -q "$1"
  (cd "$1" && echo content > file.txt && git add file.txt && git commit -qm init)
}

# Deploy BOTH kit files at the paths an adopter uses. The wrapper locates the
# neutral script by that fixed relative path, so a fixture missing either half
# is not a smaller test — it is case 13, which asserts exactly that.
deploy_hook() { # <superproject-path>
  mkdir -p "$1/.claude/hooks" "$1/scripts/agent"
  cp "$HOOK_TEMPLATE" "$1/.claude/hooks/session-start.sh"
  cp "$NEUTRAL_TEMPLATE" "$1/scripts/agent/session-start.sh"
  chmod +x "$1/.claude/hooks/session-start.sh" "$1/scripts/agent/session-start.sh"
}

# Deploy the kit and commit it, for fixtures whose assertions depend on a clean
# tree. In real adopters both files are tracked, so a fresh cloud checkout is
# porcelain-clean; deployed-but-uncommitted files are untracked, which the
# fast-forward's clean-tree guard rightly counts as dirty.
deploy_hook_committed() { # <repo-path>
  deploy_hook "$1"
  (cd "$1" && git add .claude scripts && git commit -qm "deploy cloud-sessions kit")
}

raw_hook() { # <superproject-path> — the hook's stdout verbatim (JSON, or empty)
  (cd "$1" && CLAUDE_PROJECT_DIR="$1" ./.claude/hooks/session-start.sh)
}

# Prints the decoded report, propagating the hook's own exit code. The capture
# and the status check are separate statements on purpose: `local raw="$(...)"`
# would report local's status, not the hook's, silently retiring every
# "hook exited non-zero" assertion below.
run_hook() { # <superproject-path>
  local raw rc=0
  raw="$(raw_hook "$1")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  decode_report "$raw"
}

# Fixture: a superproject with two submodules. sub-doomed is added first so a
# failure on it must not stop sub-good from initializing.
make_src_repo "$TMP/sub-doomed"
make_src_repo "$TMP/sub-good"
git init -q "$TMP/super"
(
  cd "$TMP/super"
  git commit -q --allow-empty -m root
  git submodule add -q "file://$TMP/sub-doomed" sub-doomed
  git submodule add -q "file://$TMP/sub-good" sub-good
  git commit -qm "add submodules"
)

# --- 1. a fresh clone's submodules initialize ------------------------------
git clone -q "$TMP/super" "$TMP/clone1"
deploy_hook "$TMP/clone1"
out="$(run_hook "$TMP/clone1")" || fail "hook exited non-zero on a fresh clone: $out"
echo "$out" | grep -q "initialized submodule: sub-doomed" || fail "sub-doomed not reported initialized: $out"
echo "$out" | grep -q "initialized submodule: sub-good" || fail "sub-good not reported initialized: $out"
[ -f "$TMP/clone1/sub-doomed/file.txt" ] || fail "sub-doomed has no checkout"
[ -f "$TMP/clone1/sub-good/file.txt" ] || fail "sub-good has no checkout"
echo "ok 1 - initializes uninitialized submodules"

# --- 2. initialized submodules are left alone (no yank) --------------------
(cd "$TMP/clone1/sub-good" && git commit -q --allow-empty -m wip)
before="$(git -C "$TMP/clone1/sub-good" rev-parse HEAD)"
out="$(run_hook "$TMP/clone1")" || fail "hook exited non-zero on an initialized tree: $out"
after="$(git -C "$TMP/clone1/sub-good" rev-parse HEAD)"
[ "$before" = "$after" ] || fail "hook moved an initialized submodule's HEAD ($before -> $after)"
if echo "$out" | grep -q "initialized submodule"; then
  fail "hook re-initialized an already-initialized submodule: $out"
fi
echo "ok 2 - never touches an initialized submodule"

# --- 3. drift guard, both files, both directions ---------------------------
# The guard lives in the neutral script — the half that always runs — and
# covers BOTH deployed copies. Each file is drifted separately, because a guard
# that only ever compared itself would pass the pair check while the wrapper
# rotted. Identical copies first: silence. The templates must be present in the
# fixture for the guard to run at all — the drifted cases below prove they are.
fixture_tpl="$TMP/clone1/devtools/docs/templates/cloud-sessions"
mkdir -p "$fixture_tpl"
cp "$HOOK_TEMPLATE" "$fixture_tpl/session-start.sh"
cp "$NEUTRAL_TEMPLATE" "$fixture_tpl/agent-session-start.sh"
out="$(run_hook "$TMP/clone1")" || fail "hook exited non-zero with templates present: $out"
if echo "$out" | grep -q "DRIFT"; then
  fail "DRIFT reported for byte-identical copies: $out"
fi
# Drifted wrapper: loud, and named. (Appending after the final exit 0 changes
# the bytes without changing behavior, so the drifted copy still runs.)
echo '# local hotfix' >> "$TMP/clone1/.claude/hooks/session-start.sh"
out="$(run_hook "$TMP/clone1")" || fail "hook exited non-zero when the wrapper drifted: $out"
echo "$out" | grep "DRIFT" | grep -q ".claude/hooks/session-start.sh" \
  || fail "drifted wrapper not reported by name: $out"
cp "$HOOK_TEMPLATE" "$TMP/clone1/.claude/hooks/session-start.sh"   # restore
# Drifted neutral script: equally loud, and named separately.
echo '# local hotfix' >> "$TMP/clone1/scripts/agent/session-start.sh"
out="$(run_hook "$TMP/clone1")" || fail "hook exited non-zero when the neutral script drifted: $out"
echo "$out" | grep "DRIFT" | grep -q "scripts/agent/session-start.sh" \
  || fail "drifted neutral script not reported by name: $out"
echo "$out" | grep "DRIFT" | grep -q ".claude/hooks/session-start.sh" \
  && fail "the restored wrapper was reported as drifted: $out"
cp "$NEUTRAL_TEMPLATE" "$TMP/clone1/scripts/agent/session-start.sh"   # restore
chmod +x "$TMP/clone1/scripts/agent/session-start.sh"
echo "ok 3 - drift guard covers both kit files, silent on identical, loud and specific on drift"

# --- 4. one failing submodule does not stop the rest -----------------------
rm -rf "$TMP/sub-doomed"   # sub-doomed can no longer be fetched
git clone -q "$TMP/super" "$TMP/clone2"
deploy_hook "$TMP/clone2"
out="$(run_hook "$TMP/clone2")" || fail "hook must exit 0 even when a submodule cannot initialize: $out"
echo "$out" | grep -q "could NOT initialize sub-doomed" || fail "failed submodule not reported: $out"
echo "$out" | grep -q "initialized submodule: sub-good" || fail "hook stopped at the failing submodule instead of continuing: $out"
[ -f "$TMP/clone2/sub-good/file.txt" ] || fail "sub-good has no checkout in clone2"
echo "ok 4 - per-submodule failure tolerance"

# --- 5. no submodules: silent no-op ----------------------------------------
git init -q "$TMP/plain"
(cd "$TMP/plain" && git commit -q --allow-empty -m root)
deploy_hook "$TMP/plain"
# raw_hook, not run_hook: the claim is that the hook prints NOTHING, which an
# empty-but-present JSON envelope would also satisfy after decoding.
out="$(raw_hook "$TMP/plain")" || fail "hook must exit 0 in a repo with no submodules: $out"
[ -z "$out" ] || fail "expected byte-empty stdout in a repo with no submodules, got: $out"
echo "ok 5 - silent no-op without submodules"

# --- 6. freshness: fetch + staleness report --------------------------------
# A submodule-free source repo keeps the output down to the freshness line.
# The fixture deletes origin/HEAD to pin the symbolic-ref fallback: a
# platform clone (init + fetch, no `git clone`) has no origin/HEAD, and
# rev-parse --abbrev-ref echoed the unresolved name into the report
# (caught live, llmkit-dev 2026-07-18).
make_src_repo "$TMP/fresh-src"
git clone -q "$TMP/fresh-src" "$TMP/clone3"
deploy_hook "$TMP/clone3"
(cd "$TMP/clone3" && git remote set-head origin --delete)
out="$(run_hook "$TMP/clone3")" || fail "hook exited non-zero on an up-to-date clone: $out"
echo "$out" | grep -q "local main is up to date with origin/main" || fail "up-to-date not reported: $out"
git -C "$TMP/clone3" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null \
  || fail "origin/HEAD not restored by set-head (platform clones lack it)"
# A branch deleted on the remote must be pruned from the tracking refs —
# stale ones make range-based tooling misread merged history as unpushed.
(cd "$TMP/fresh-src" && git branch -q doomed)
git -C "$TMP/clone3" fetch -q origin
git -C "$TMP/clone3" rev-parse -q --verify refs/remotes/origin/doomed >/dev/null || fail "fixture: tracking ref for doomed not created"
(cd "$TMP/fresh-src" && git branch -qD doomed)
(cd "$TMP/fresh-src" && git commit -q --allow-empty -m ahead1 && git commit -q --allow-empty -m ahead2)
before="$(git -C "$TMP/clone3" rev-parse main)"
out="$(run_hook "$TMP/clone3")" || fail "hook exited non-zero on a stale clone: $out"
echo "$out" | grep -q "local main is 2 commit(s) behind origin/main" || fail "staleness not reported: $out"
[ "$(git -C "$TMP/clone3" rev-parse main)" = "$before" ] || fail "hook moved local main — the report must never mutate"
git -C "$TMP/clone3" rev-parse -q --verify refs/remotes/origin/doomed >/dev/null \
  && fail "stale tracking ref origin/doomed not pruned by the hook's fetch"
(cd "$TMP/clone3" && git remote set-url origin "file://$TMP/no-such-repo")
out="$(run_hook "$TMP/clone3")" || fail "hook must exit 0 when the fetch fails: $out"
echo "$out" | grep -q "git fetch origin FAILED" || fail "failed fetch not reported loudly: $out"
echo "ok 6 - fetch + staleness report (report only, loud on failure)"

# --- 7. cloud auto-sync: guarded fast-forward + submodule re-sync ----------
# A cloud session (CLAUDE_CODE_REMOTE=true) starts on a working branch cut
# from the snapshot's stale default branch, clean and with no commits of its
# own — the hook fast-forwards it, carries local main along, and re-syncs
# the initialized submodule to the moved pointer. With a local commit or a
# dirty tree the fast-forward is withheld and only the report prints.
# The kit is deployed and COMMITTED into the source superproject before cloning,
# so the clone is porcelain-clean and the fast-forward's clean-tree guard is
# testing what it means to test. (Deploying into the clone instead would either
# leave untracked files — read as dirty — or add a local commit, which the
# no-local-commits guard withholds the fast-forward for. Both would pass the
# fixture while proving nothing.) The wrapper is invoked at its deployed path,
# because it locates the neutral script relative to the project root.
raw_hook_cloud() { # <superproject-path> — hook stdout verbatim, cloud env
  (cd "$1" && CLAUDE_PROJECT_DIR="$1" CLAUDE_CODE_REMOTE=true ./.claude/hooks/session-start.sh)
}

run_hook_cloud() { # <superproject-path>
  local raw rc=0
  raw="$(raw_hook_cloud "$1")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  decode_report "$raw"
}
make_src_repo "$TMP/sync-sub"
git init -q "$TMP/sync-super"
(
  cd "$TMP/sync-super"
  git commit -q --allow-empty -m root
  git submodule add -q "file://$TMP/sync-sub" sub
  git commit -qm "add submodule"
)
deploy_hook_committed "$TMP/sync-super"
git clone -q "$TMP/sync-super" "$TMP/clone4"
git -C "$TMP/clone4" submodule update --init -q
git -C "$TMP/clone4" checkout -qb claude/task     # the platform's session branch

# Advance the remote: a submodule commit and a superproject pointer bump.
(cd "$TMP/sync-sub" && echo more > file.txt && git commit -qam advance)
(cd "$TMP/sync-super" && git -C sub pull -q origin main && git add sub && git commit -qm "bump sub pointer")
new_tip="$(git -C "$TMP/sync-super" rev-parse HEAD)"
new_sub="$(git -C "$TMP/sync-sub" rev-parse HEAD)"
out="$(run_hook_cloud "$TMP/clone4")" || fail "hook exited non-zero on cloud auto-sync: $out"
echo "$out" | grep -q "fast-forwarded claude/task" || fail "fast-forward not performed/reported: $out"
[ "$(git -C "$TMP/clone4" rev-parse HEAD)" = "$new_tip" ] || fail "working branch not at the remote tip after auto-sync"
[ "$(git -C "$TMP/clone4" rev-parse main)" = "$new_tip" ] || fail "local main not carried along"
[ "$(git -C "$TMP/clone4/sub" rev-parse HEAD)" = "$new_sub" ] || fail "submodule not re-synced to the moved pointer"
echo "$out" | grep -q "synced submodule to the fast-forwarded pointer: sub" || fail "submodule re-sync not reported: $out"
# Guard: a local commit withholds the fast-forward.
(cd "$TMP/sync-super" && git commit -q --allow-empty -m ahead-again)
(cd "$TMP/clone4" && git commit -q --allow-empty -m local-work)
before="$(git -C "$TMP/clone4" rev-parse HEAD)"
out="$(run_hook_cloud "$TMP/clone4")" || fail "hook exited non-zero on the ahead guard: $out"
echo "$out" | grep -q "fast-forwarded" && fail "fast-forwarded a branch carrying local commits: $out"
[ "$(git -C "$TMP/clone4" rev-parse HEAD)" = "$before" ] || fail "ahead guard failed — HEAD moved"
echo "$out" | grep -q "behind origin/main" || fail "withheld sync must still report staleness: $out"
# Guard: a dirty tree withholds the fast-forward (fresh clean-history clone).
git clone -q "$TMP/sync-super" "$TMP/clone5"
git -C "$TMP/clone5" submodule update --init -q
git -C "$TMP/clone5" checkout -qb claude/task2

(cd "$TMP/sync-super" && git commit -q --allow-empty -m ahead-yet-again)
touch "$TMP/clone5/scratch.txt"
before="$(git -C "$TMP/clone5" rev-parse HEAD)"
out="$(run_hook_cloud "$TMP/clone5")" || fail "hook exited non-zero on the dirty guard: $out"
echo "$out" | grep -q "fast-forwarded" && fail "fast-forwarded with a dirty tree: $out"
[ "$(git -C "$TMP/clone5" rev-parse HEAD)" = "$before" ] || fail "dirty guard failed — HEAD moved"
echo "ok 7 - cloud auto-sync (fast-forward + submodule re-sync, withheld on local commits or dirty tree)"

# --- 8. a failed token init must not repoint the superproject's origin ------
# Regression (found-in-words-cms, 2026-07-19): init_via_token()'s cleanup line
# `git -C "$path" remote set-url origin "$url"` ran even when the token fetch
# failed and left the submodule worktree empty. With no .git there, `git -C`
# resolves the ENCLOSING superproject and repoints ITS origin at the submodule
# URL — cms's origin ended up pointing at devtools, surfacing as a phantom "10
# extra commits" in origin/main..HEAD. The fix guards the cleanup on the
# worktree being a real repo.
#
# Hermetic failure, no network: the submodule's .gitmodules URL is a github.com
# URL (so the token-fallback branch is reached), and BOTH the plain and the
# token-authed forms are rewritten via insteadOf to a path that does not exist,
# so the proxy init AND the token retry both fail deterministically.
TOK="TESTTOKEN"
NOPE="$TMP/nope"                       # never created — any fetch rewritten here fails
git config --global "url.file://$NOPE/.insteadOf" "https://github.com/"
git config --global --add "url.file://$NOPE/.insteadOf" "https://x-access-token:$TOK@github.com/"
make_src_repo "$TMP/tok-sub"           # seeds a valid gitlink; never actually fetched
git init -q "$TMP/tok-super"
(
  cd "$TMP/tok-super"
  git commit -q --allow-empty -m root
  git submodule add -q "file://$TMP/tok-sub" sub
  git config --file .gitmodules submodule.sub.url "https://github.com/omgbrews/tok-sub"
  git add .gitmodules && git commit -qm "add submodule (github url)"
)
git clone -q "$TMP/tok-super" "$TMP/clone6"
deploy_hook "$TMP/clone6"
origin_before="$(git -C "$TMP/clone6" config --get remote.origin.url)"
raw="$(cd "$TMP/clone6" && CLAUDE_PROJECT_DIR="$TMP/clone6" CLAUDE_CODE_REMOTE=true \
       SUBMODULE_READ_TOKEN="$TOK" ./.claude/hooks/session-start.sh)" \
  || fail "hook must exit 0 when a token init fails: $raw"
out="$(decode_report "$raw")"
echo "$out" | grep -q "could NOT initialize sub" || fail "failed token init not reported: $out"
[ ! -e "$TMP/clone6/sub/.git" ] || fail "fixture invalid: the submodule unexpectedly initialized"
origin_after="$(git -C "$TMP/clone6" config --get remote.origin.url)"
[ "$origin_after" = "$origin_before" ] \
  || fail "a failed token init repointed the superproject origin: $origin_before -> $origin_after"
git config --global --unset-all "url.file://$NOPE/.insteadOf"
echo "ok 8 - a failed token init leaves the superproject origin untouched"

# --- 9. a transient fetch failure is retried, not fatal ---------------------
# Regression (found-in-words-cms, 2026-07-24): the session's git proxy injects
# its credential a beat after startup, so a fetch fired at t=0 fails with "could
# not read Password"/"terminal prompts disabled" while the identical fetch
# succeeds seconds later. Pre-fix the hook fetched exactly once, so that single
# miss stranded the checkout at snapshot age — skipping the fast-forward and the
# submodule resync — for the whole session. The hook must now retry, reach the
# freshness report, and NOT emit the FAILED line for a miss a retry clears. A
# `git` shim on PATH fails only the FIRST `fetch` and delegates everything else.
make_src_repo "$TMP/retry-src"
git clone -q "$TMP/retry-src" "$TMP/clone-retry"
deploy_hook "$TMP/clone-retry"
(cd "$TMP/retry-src" && git commit -q --allow-empty -m ahead1)  # one commit to report
shimdir="$TMP/shim"
mkdir -p "$shimdir"
realgit="$(command -v git)"
cat > "$shimdir/git" <<'SHIM'
#!/usr/bin/env bash
# Fail the first `git fetch` (proxy-credential race), delegate everything else.
if [ "${1:-}" = fetch ]; then
  n=$(( $(cat "$SHIM_STATE" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$SHIM_STATE"
  if [ "$n" -eq 1 ]; then
    echo "fatal: could not read Password for 'http://local_proxy@127.0.0.1': terminal prompts disabled" >&2
    exit 128
  fi
fi
exec "$SHIM_REALGIT" "$@"
SHIM
chmod +x "$shimdir/git"
raw="$(cd "$TMP/clone-retry" && PATH="$shimdir:$PATH" SHIM_STATE="$TMP/retry-count" \
       SHIM_REALGIT="$realgit" CLAUDE_PROJECT_DIR="$TMP/clone-retry" \
       ./.claude/hooks/session-start.sh)" \
  || fail "hook exited non-zero when the first fetch failed transiently: $raw"
out="$(decode_report "$raw")"
echo "$out" | grep -q "local main is 1 commit(s) behind origin/main" \
  || fail "transient fetch failure not retried to the freshness report: $out"
echo "$out" | grep -q "git fetch origin FAILED" \
  && fail "hook reported FAILED despite a successful retry: $out"
[ "$(cat "$TMP/retry-count")" -ge 2 ] || fail "hook did not actually retry the fetch"
echo "ok 9 - transient fetch failure is retried, not fatal"

# --- 10. parent-side pointer check: recorded gitlink vs the child's tip ------
# The check exists because a session reading a child through a stale pointer
# sees a tree missing work that exists on the child's remote (found-in-words
# cms, 2026-07-21: 14 commits and 11 task documents invisible behind a stale
# pointer). Every direction the block implements is asserted, because a test
# that only proves the lagging case cannot tell whether the silent cases are
# silent from being in sync or from the block never running — and (g) is there
# because the first implementation's tip parser reported lag most confidently
# exactly where it was wrong.
#
# One fixture carries BOTH edge classes: decl-sub is declared (`branch = main`,
# added with -b), pinned-sub is pinned (no branch key). Both children then
# advance, so the pin's silence is a property of the discriminator rather than
# of nothing having moved. file:// sources keep `git ls-remote` offline.
make_src_repo "$TMP/lag-decl"
make_src_repo "$TMP/lag-pin"
git init -q "$TMP/lag-super"
(
  cd "$TMP/lag-super"
  git commit -q --allow-empty -m root
  git submodule add -q -b main "file://$TMP/lag-decl" decl-sub
  git submodule add -q "file://$TMP/lag-pin" pinned-sub
  git commit -qm "add submodules (one declared, one pinned)"
)
git -C "$TMP/lag-super" config -f .gitmodules --get submodule.decl-sub.branch >/dev/null \
  || fail "fixture invalid: decl-sub is not a declared edge"
git -C "$TMP/lag-super" config -f .gitmodules --get submodule.pinned-sub.branch >/dev/null \
  && fail "fixture invalid: pinned-sub carries a branch key"
git clone -q "$TMP/lag-super" "$TMP/clone-lag"
deploy_hook "$TMP/clone-lag"

# (a) recorded pointer == remote tip: no lag line.
out="$(run_hook "$TMP/clone-lag")" || fail "hook exited non-zero with in-sync pointers: $out"
echo "$out" | grep -q "HEAD records" && fail "lag reported for an in-sync pointer: $out"
echo "$out" | grep -q "could NOT check the recorded pointer" && fail "in-sync pointer reported as uncheckable: $out"

# (b) the child's remote advances; the superproject's recorded pointer does not.
(cd "$TMP/lag-decl" && git commit -q --allow-empty -m advance)
(cd "$TMP/lag-pin" && git commit -q --allow-empty -m advance)
rec="$(git -C "$TMP/clone-lag" ls-tree HEAD -- decl-sub | awk '{print $3}')"
tip="$(git -C "$TMP/lag-decl" rev-parse HEAD)"
[ "$rec" != "$tip" ] || fail "fixture invalid: recorded pointer already equals the advanced tip"
out="$(run_hook "$TMP/clone-lag")" || fail "hook exited non-zero with a lagging pointer: $out"
echo "$out" | grep "decl-sub" | grep -q "${rec:0:7}" || fail "lag line does not name the recorded SHA: $out"
echo "$out" | grep "decl-sub" | grep -q "${tip:0:7}" || fail "lag line does not name the remote tip SHA: $out"
[ "$(git -C "$TMP/clone-lag" ls-tree HEAD -- decl-sub | awk '{print $3}')" = "$rec" ] \
  || fail "the pointer check moved the recorded gitlink — it must only report"

# (c) the pinned edge advanced too, and stays silent by design: its writer is an
#     explicit propagation, not this session.
echo "$out" | grep -q "pinned-sub" && fail "pinned edge reported — the branch key is the discriminator: $out"

# (d) an unreachable child is reported as UNCHECKED, never skipped quietly: a
#     skipped check is indistinguishable from a passing one (signal-hygiene.md).
rm -rf "$TMP/lag-decl"
out="$(run_hook "$TMP/clone-lag")" || fail "hook must exit 0 when ls-remote cannot reach the child: $out"
echo "$out" | grep -q "could NOT check the recorded pointer for decl-sub" \
  || fail "unreachable child not reported as unchecked: $out"

# (e) the child's remote answers, but carries no branch of the declared name:
#     unchecked, naming the ref .gitmodules claims the edge tracks. A branch
#     renamed on the child leaves the parent tracking a ref that no longer
#     exists, and "no tip found" must never read as "in sync".
make_src_repo "$TMP/lag-decl"          # recreate the child (d) removed; it has main only
git -C "$TMP/clone-lag" config -f .gitmodules submodule.decl-sub.branch develop
out="$(run_hook "$TMP/clone-lag")" || fail "hook must exit 0 when the declared branch is absent: $out"
echo "$out" | grep -q "has no refs/heads/develop" \
  || fail "declared branch missing from the child's remote not reported: $out"
git -C "$TMP/clone-lag" config -f .gitmodules submodule.decl-sub.branch main

# (f) a declared entry whose path HEAD records no gitlink for. .gitmodules is a
#     plain file that can name a path the tree does not carry (a half-landed
#     removal, a hand edit), and there is then nothing to compare — say so
#     rather than comparing an empty string against a real SHA.
git -C "$TMP/clone-lag" config -f .gitmodules submodule.ghost.path ghost
git -C "$TMP/clone-lag" config -f .gitmodules submodule.ghost.url "file://$TMP/lag-decl"
git -C "$TMP/clone-lag" config -f .gitmodules submodule.ghost.branch main
out="$(run_hook "$TMP/clone-lag")" || fail "hook must exit 0 for a declared entry with no gitlink: $out"
echo "$out" | grep -q "ghost is declared in .gitmodules (branch = main) but HEAD records no gitlink" \
  || fail "declared entry with no recorded gitlink not reported: $out"
git -C "$TMP/clone-lag" config -f .gitmodules --remove-section submodule.ghost

# (g) stderr on a SUCCESSFUL ls-remote must not become the tip. The capture
#     merges stderr so a failure can be quoted, and git writes to stderr while
#     succeeding — "warning: redirecting to https://…" on an http:// URL. Taking
#     the first field of the first non-empty line then yields `warning:`: seven
#     characters, so it prints as a plausible short SHA and the hook emits a
#     confident lag report for an edge that is provably in sync. Same `git`-shim
#     technique as case 9, against an in-sync edge, asserting silence.
make_src_repo "$TMP/warn-decl"
git init -q "$TMP/warn-super"
(
  cd "$TMP/warn-super"
  git commit -q --allow-empty -m root
  git submodule add -q -b main "file://$TMP/warn-decl" decl-sub
  git commit -qm "add declared submodule"
)
git clone -q "$TMP/warn-super" "$TMP/clone-warn"
deploy_hook "$TMP/clone-warn"
warnshim="$TMP/shim-lsremote"
mkdir -p "$warnshim"
cat > "$warnshim/git" <<'SHIM'
#!/usr/bin/env bash
# Real git, plus the line git itself prints on stderr when a URL redirects.
if [ "${1:-}" = ls-remote ]; then
  echo "warning: redirecting to https://github.com/OMGBrews/warn-decl.git/" >&2
fi
exec "$SHIM_REALGIT" "$@"
SHIM
chmod +x "$warnshim/git"
raw="$(cd "$TMP/clone-warn" && PATH="$warnshim:$PATH" SHIM_REALGIT="$realgit" \
       CLAUDE_PROJECT_DIR="$TMP/clone-warn" ./.claude/hooks/session-start.sh)" \
  || fail "hook exited non-zero when ls-remote warned on stderr: $raw"
out="$(decode_report "$raw")"
echo "$out" | grep -q "HEAD records" \
  && fail "stderr from a successful ls-remote was parsed as the remote tip: $out"
echo "$out" | grep -q "could NOT check the recorded pointer" \
  && fail "a stderr warning made an in-sync edge report as uncheckable: $out"
echo "ok 10 - parent-side pointer check (declared only; silent in sync, loud on lag, on failure, on a missing branch or gitlink; stderr is never the tip)"

# --- 11. JSON output contract + the reload request --------------------------
# The hook's stdout is one JSON object so it can carry `reloadSkills`, which
# rebuilds the skill registry after the hook completes. Without it, a repo
# whose .claude/skills/* symlinks point into a submodule that was uninitialized
# when the registry was built keeps every shared skill readable-but-uninvocable
# for the whole session (found-in-words-cms, 2026-07-29: `/ship` answered
# `Unknown skill: ship` while its SKILL.md sat on disk).
make_src_repo "$TMP/j-sub"
git init -q "$TMP/j-super"
(
  cd "$TMP/j-super"
  git commit -q --allow-empty -m root
  git submodule add -q "file://$TMP/j-sub" sub
  git commit -qm "add submodule"
)
deploy_hook_committed "$TMP/j-super"   # (c) below clones this and needs the kit tracked
git clone -q "$TMP/j-super" "$TMP/clone-json"

# (a) a run that initializes a submodule asks for the rebuild.
raw="$(raw_hook "$TMP/clone-json")" || fail "hook exited non-zero on the JSON fixture: $raw"
printf '%s' "$raw" | json_valid || fail "hook stdout is not valid JSON: $raw"
[ "$(printf '%s' "$raw" | wc -l)" -eq 0 ] \
  || fail "hook stdout spans multiple lines — a report newline escaped unencoded: $raw"
[ "$(printf '%s' "$raw" | json_get hookEventName)" = "SessionStart" ] \
  || fail "hookSpecificOutput.hookEventName is not SessionStart: $raw"
[ "$(printf '%s' "$raw" | json_get reloadSkills)" = "true" ] \
  || fail "a run that initialized a submodule did not request the skill reload: $raw"
printf '%s' "$raw" | json_get additionalContext | grep -q "initialized submodule: sub" \
  || fail "the report did not survive into additionalContext: $raw"

# (b) THE DISCRIMINATOR: a run that changes nothing must not ask. Without this,
#     a hardcoded `"reloadSkills":true` passes (a) and every other assertion.
#     The report check keeps it honest — it proves this run produced output at
#     all, so "no reload requested" is a real answer and not an empty stdout.
raw="$(raw_hook "$TMP/clone-json")" || fail "hook exited non-zero on the second run: $raw"
printf '%s' "$raw" | json_get additionalContext | grep -q "up to date with origin/main" \
  || fail "fixture invalid: the second run reported nothing, so the reload check proves nothing: $raw"
[ "$(printf '%s' "$raw" | json_get reloadSkills)" != "true" ] \
  || fail "reloadSkills requested by a run that initialized nothing: $raw"

# (c) the cloud re-sync path asks too: a moved pointer replaces the submodule's
#     checkout, so skills that came from it are stale until the registry reloads.
git clone -q "$TMP/j-super" "$TMP/clone-json2"
git -C "$TMP/clone-json2" submodule update --init -q
git -C "$TMP/clone-json2" checkout -qb claude/task-json
(cd "$TMP/j-sub" && echo more > file.txt && git commit -qam advance)
(cd "$TMP/j-super" && git -C sub pull -q origin main && git add sub && git commit -qm "bump sub pointer")
raw="$(raw_hook_cloud "$TMP/clone-json2")" || fail "hook exited non-zero on the resync fixture: $raw"
printf '%s' "$raw" | json_get additionalContext | grep -q "synced submodule to the fast-forwarded pointer" \
  || fail "fixture invalid: no re-sync happened, so its reload check proves nothing: $raw"
[ "$(printf '%s' "$raw" | json_get reloadSkills)" = "true" ] \
  || fail "a submodule re-sync did not request the skill reload: $raw"

# (d) report text carrying JSON metacharacters must not break the envelope. A
#     submodule URL is echoed verbatim on the failure path, so a URL holding a
#     double quote and a backslash exercises the escaping end to end. insteadOf
#     rewrites the fetch to a path that does not exist, so it fails offline and
#     instantly (same technique as case 8).
NOPE2="$TMP/nope2"
git config --global "url.file://$NOPE2/.insteadOf" "https://github.com/"
WEIRD_URL='https://github.com/omgbrews/we"ird\sub'
git init -q "$TMP/esc-super"
(
  cd "$TMP/esc-super"
  git commit -q --allow-empty -m root
  git submodule add -q "file://$TMP/j-sub" sub
  git config --file .gitmodules submodule.sub.url "$WEIRD_URL"
  git add .gitmodules && git commit -qm "url with JSON metacharacters"
)
git clone -q "$TMP/esc-super" "$TMP/clone-esc"
deploy_hook "$TMP/clone-esc"
raw="$(raw_hook "$TMP/clone-esc")" || fail "hook exited non-zero on the escaping fixture: $raw"
printf '%s' "$raw" | json_valid \
  || fail "a report containing a quote and a backslash produced invalid JSON: $raw"
printf '%s' "$raw" | json_get additionalContext | grep -qF "$WEIRD_URL" \
  || fail "the URL did not survive JSON escaping intact: $raw"
git config --global --unset-all "url.file://$NOPE2/.insteadOf"
echo "ok 11 - JSON envelope, report round-trip, and reloadSkills exactly when a submodule changed"

# --- 12. the neutral script is a plain command, usable with no harness -------
# The reason the bootstrap was split out of the hook: a session in Codex,
# Cursor, opencode, a CI job, or a human's terminal must get the same fetch,
# the same submodule init, and the same report. Asserted directly rather than
# inferred from the wrapper passing — the wrapper could satisfy every case
# above while the neutral half quietly depended on a CLAUDE_* variable.
make_src_repo "$TMP/n-sub"
git init -q "$TMP/n-super"
(
  cd "$TMP/n-super"
  git commit -q --allow-empty -m root
  git submodule add -q "file://$TMP/n-sub" sub
  git commit -qm "add submodule"
)
git clone -q "$TMP/n-super" "$TMP/clone-neutral"
deploy_hook "$TMP/clone-neutral"

# No wrapper, and every vendor variable explicitly out of the environment.
marker="$TMP/neutral-marker"; : > "$marker"
raw="$(cd "$TMP/clone-neutral" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_REMOTE \
       AGENT_BOOTSTRAP_RELOAD_MARKER="$marker" bash scripts/agent/session-start.sh)" \
  || fail "the neutral script exited non-zero run as a plain command: $raw"
[ -f "$TMP/clone-neutral/sub/file.txt" ] \
  || fail "the neutral script did not initialize the submodule without a harness"
echo "$raw" | grep -q "initialized submodule: sub" \
  || fail "the neutral script did not report the init as plain text: $raw"
case "$raw" in
  *hookSpecificOutput*) fail "the neutral script emitted the vendor JSON envelope: $raw" ;;
esac
# The marker is the wrapper's only channel for the reload request, so it is
# part of the neutral script's contract — and its discriminator is that a run
# changing nothing leaves it empty.
[ -s "$marker" ] || fail "the neutral script did not write the reload marker after an init"
: > "$marker"
raw="$(cd "$TMP/clone-neutral" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_REMOTE \
       AGENT_BOOTSTRAP_RELOAD_MARKER="$marker" bash scripts/agent/session-start.sh)" \
  || fail "the neutral script exited non-zero on its second run: $raw"
echo "$raw" | grep -q "up to date with origin/main" \
  || fail "fixture invalid: the second run reported nothing, so the marker check proves nothing: $raw"
[ -s "$marker" ] && fail "the neutral script wrote the reload marker on a run that changed nothing"

# (c) THE DISCRIMINATOR for the split: the ephemeral path must be licensed by
#     AGENT_SESSION_EPHEMERAL ALONE. Every other cloud case above runs through
#     the wrapper with CLAUDE_CODE_REMOTE=true in the environment, which the
#     neutral script inherits — so a neutral script that simply kept reading the
#     vendor variable passes all of them, and the split would be cosmetic. This
#     case sets the neutral variable with the vendor one explicitly unset, so it
#     fails exactly when the harness dependency leaks back in. (Verified by
#     mutation: reverting _ephemeral() to read CLAUDE_CODE_REMOTE leaves the
#     rest of this file green and turns this assertion red.)
make_src_repo "$TMP/e-sub"
git init -q "$TMP/e-super"
(
  cd "$TMP/e-super"
  git commit -q --allow-empty -m root
  git submodule add -q "file://$TMP/e-sub" sub
  git commit -qm "add submodule"
)
deploy_hook_committed "$TMP/e-super"
git clone -q "$TMP/e-super" "$TMP/clone-eph"
git -C "$TMP/clone-eph" submodule update --init -q
git -C "$TMP/clone-eph" checkout -qb agent/task
(cd "$TMP/e-sub" && echo more > file.txt && git commit -qam advance)
(cd "$TMP/e-super" && git -C sub pull -q origin main && git add sub && git commit -qm "bump sub pointer")
eph_tip="$(git -C "$TMP/e-super" rev-parse HEAD)"
eph_sub="$(git -C "$TMP/e-sub" rev-parse HEAD)"
raw="$(cd "$TMP/clone-eph" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_REMOTE \
       AGENT_SESSION_EPHEMERAL=true bash scripts/agent/session-start.sh)" \
  || fail "the neutral script exited non-zero on the ephemeral path: $raw"
echo "$raw" | grep -q "fast-forwarded agent/task" \
  || fail "AGENT_SESSION_EPHEMERAL alone did not license the fast-forward — the neutral script is still reading a vendor variable: $raw"
[ "$(git -C "$TMP/clone-eph" rev-parse HEAD)" = "$eph_tip" ] \
  || fail "working branch not at the remote tip after a neutral-variable fast-forward"
[ "$(git -C "$TMP/clone-eph/sub" rev-parse HEAD)" = "$eph_sub" ] \
  || fail "submodule not re-synced on the neutral-variable ephemeral path"
echo "ok 12 - the neutral script works as a plain command, signals reloads via the marker, and takes its ephemeral licence from the neutral variable alone"

# --- 13. a missing bootstrap is reported, never silently skipped ------------
# The failure the split introduces: the hook fires, the neutral script is not
# there (a devtools bump that landed the split without the matching redeploy),
# and nothing bootstraps. Its symptom is a stale checkout with uninitialized
# submodules, which is indistinguishable from a healthy session — so the
# wrapper has to say so itself (signal-hygiene.md).
git clone -q "$TMP/n-super" "$TMP/clone-nowrap"
mkdir -p "$TMP/clone-nowrap/.claude/hooks"
cp "$HOOK_TEMPLATE" "$TMP/clone-nowrap/.claude/hooks/session-start.sh"
chmod +x "$TMP/clone-nowrap/.claude/hooks/session-start.sh"
raw="$(raw_hook "$TMP/clone-nowrap")" || fail "the wrapper exited non-zero with no bootstrap present: $raw"
[ -n "$raw" ] || fail "the wrapper was byte-silent with no bootstrap present — the exact failure this case exists to catch"
printf '%s' "$raw" | json_valid || fail "the missing-bootstrap report is not valid JSON: $raw"
report="$(printf '%s' "$raw" | json_get additionalContext)"
echo "$report" | grep -q "MISSING" || fail "the missing bootstrap was not reported as missing: $report"
echo "$report" | grep -q "agent-session-start.sh" \
  || fail "the report does not name the template to redeploy from: $report"
[ "$(printf '%s' "$raw" | json_get reloadSkills)" != "true" ] \
  || fail "a run that bootstrapped nothing requested a skill reload: $raw"
[ ! -e "$TMP/clone-nowrap/sub/.git" ] \
  || fail "fixture invalid: the submodule initialized, so no bootstrap was actually missing"
echo "ok 13 - a missing neutral script is reported loudly, with the redeploy named"

# --- 14. a workshop/-named mount is discovered, not just devtools/ ----------
# The fleet mounts the shared tools as devtools/; a public consumer mounts the
# Workshop mirror as workshop/. The bootstrap must find the kit under EITHER
# name — the drift guard compares against the right template and the roster
# seam wires the right hooksPath — and a discovery that only ever read the
# devtools/ name would false-pass every case above, so this one mounts the kit
# as workshop/ and asserts both seams resolve through it. (The super fixture's
# sub-doomed source is gone by now; per-submodule tolerance keeps the hook at
# exit 0, which the assertions below do not rely on either way.)
git clone -q "$TMP/super" "$TMP/clone-ws"
deploy_hook "$TMP/clone-ws"
ws="$TMP/clone-ws/workshop"
mkdir -p "$ws/docs/templates/cloud-sessions" "$ws/Tools/hooks"
cp "$HOOK_TEMPLATE" "$ws/docs/templates/cloud-sessions/session-start.sh"
cp "$NEUTRAL_TEMPLATE" "$ws/docs/templates/cloud-sessions/agent-session-start.sh"
cp "$DEVTOOLS_ROOT/Tools/check-skill-roster-freshness.sh" "$ws/Tools/"
cp "$DEVTOOLS_ROOT"/Tools/hooks/post-checkout "$DEVTOOLS_ROOT"/Tools/hooks/post-merge "$DEVTOOLS_ROOT"/Tools/hooks/post-rewrite "$ws/Tools/hooks/"
out="$(run_hook "$TMP/clone-ws")" || fail "hook exited non-zero with a workshop/ mount: $out"
echo "$out" | grep -q "DRIFT" \
  && fail "DRIFT reported for byte-identical copies under a workshop/ mount: $out"
hp="$(git -C "$TMP/clone-ws" config --get core.hooksPath)"
[ "$hp" = "workshop/Tools/hooks" ] \
  || fail "roster seam wired the wrong hooksPath under a workshop/ mount (got '$hp')"
echo "ok 14 - a workshop/-named mount is discovered: drift silent against its templates, hooksPath wired into it"

# --- 15. a .gitmodules-discovered mount is not discarded by read parsing ----
# Conventional names are only a fast path. For every other mount the fallback
# reads `git config --get-regexp`, whose key and path must be split into two
# fields. `IFS=` makes the entire line the key and leaves the path empty, so a
# generic mount silently loses both its drift guard and roster hook wiring.
git clone -q "$TMP/super" "$TMP/clone-generic"
deploy_hook "$TMP/clone-generic"
generic="$TMP/clone-generic/shared-kit"
mkdir -p "$generic/docs/templates/cloud-sessions" "$generic/Tools/hooks"
cp "$HOOK_TEMPLATE" "$generic/docs/templates/cloud-sessions/session-start.sh"
cp "$NEUTRAL_TEMPLATE" "$generic/docs/templates/cloud-sessions/agent-session-start.sh"
cp "$DEVTOOLS_ROOT/Tools/check-skill-roster-freshness.sh" "$generic/Tools/"
cp "$DEVTOOLS_ROOT"/Tools/hooks/post-checkout "$DEVTOOLS_ROOT"/Tools/hooks/post-merge "$DEVTOOLS_ROOT"/Tools/hooks/post-rewrite "$generic/Tools/hooks/"
git -C "$TMP/clone-generic" config -f .gitmodules submodule.shared-kit.path shared-kit
out="$(run_hook "$TMP/clone-generic")" || fail "hook exited non-zero with a generic kit mount: $out"
echo "$out" | grep -q "DRIFT" \
  && fail "DRIFT reported for byte-identical copies under a generic mount: $out"
hp="$(git -C "$TMP/clone-generic" config --get core.hooksPath)"
[ "$hp" = "shared-kit/Tools/hooks" ] \
  || fail "roster seam did not use the generic .gitmodules mount (got '$hp')"
echo "ok 15 - a generic .gitmodules mount is discovered: drift silent against its templates, hooksPath wired into it"
