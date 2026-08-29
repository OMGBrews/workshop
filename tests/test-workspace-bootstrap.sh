#!/usr/bin/env bash
# Tests for Tools/devcontainer/workspace-bootstrap.sh — the first-boot populate
# that fills an empty volume workspace.
#
# The contract, asserted here:
#   1. the clone runs with git's interactive prompt disabled, so a context that
#      has a terminal but no credentials cannot sit on "Username for ...";
#   2. a populate that never succeeds exits NON-ZERO, in both lifecycle phases —
#      it used to exit 0, which made a failed first boot indistinguishable from
#      a good one to anything scripted;
#   3. the message names the repo it tried, and its advice matches what git
#      actually said: missing credentials and "no such repository" need opposite
#      advice, and an unrecognized failure quotes git instead of guessing;
#   4. the success paths are untouched — a clone that works still hands off to
#      the lifecycle scripts, and an already-populated workspace is left alone.
#
# TEST 1 is the one that matters most, and it is why this file asserts on the
# environment git is called with rather than on a timeout. With the prompt
# enabled the script does not fail: it *waits*, forever and invisibly, looking
# exactly like a slow build. That cost half an hour of the 2026-07-31 fleet
# rebuild before anyone thought to run the clone by hand.
set -euo pipefail

DEVTOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$DEVTOOLS_ROOT/Tools/devcontainer/workspace-bootstrap.sh"
URL="https://github.com/OMGBrews/example-repo.git"

fail() { echo "FAIL: $1" >&2; echo "--- last run output ---" >&2; echo "$OUT" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A stand-in git whose behaviour SHIM_MODE picks, so every failure shape is
# exercised offline and deterministically — including the ones this machine
# cannot produce for real (a "not found" needs credentials that DO work). The
# no-op sleep keeps the script's 5s credential-race retries from making this
# suite crawl; the real cadence is deliberate and stays untested here.
SHIM="$TMP/shim"
mkdir -p "$SHIM"
cat > "$SHIM/git" <<'SHIM_EOF'
#!/usr/bin/env bash
dest="${*: -1}"
case "${SHIM_MODE:-}" in
  envcheck)
    echo "SHIM saw GIT_TERMINAL_PROMPT=[${GIT_TERMINAL_PROMPT:-unset}]" >&2
    exit 128 ;;
  noauth)
    echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2
    exit 128 ;;
  notfound)
    echo "remote: Repository not found." >&2
    echo "fatal: repository 'https://github.com/OMGBrews/example-repo.git/' not found" >&2
    exit 128 ;;
  weird)
    echo "fatal: unable to access 'https://github.com/OMGBrews/example-repo.git/': Could not resolve host: github.com" >&2
    exit 128 ;;
  ok)
    echo "Cloning into '$dest'..."
    mkdir -p "$dest/.git"
    [ -n "${SHIM_COUNT_FILE:-}" ] && echo "$(( $(cat "$SHIM_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))" > "$SHIM_COUNT_FILE"
    exit 0 ;;
  slow)
    # A clone that has started but not finished: .git exists (which is what the
    # old populated-guard false-passed on), the post_install wrapper stub is in
    # place, but devtools — the "submodule" — has not arrived yet. The clone
    # blocks on a handshake file so the test can hold it mid-flight.
    echo "Cloning into '$dest'..."
    mkdir -p "$dest/.git"
    mkdir -p "$dest/.devcontainer/scripts"
    cat > "$dest/.devcontainer/scripts/post_install.sh" <<'STUB_EOF'
#!/bin/bash
# Stub wrapper: fails while devtools ("the submodule") is absent — the real
# wrapper's `bash devtools/.../post_install.sh` would fail with "No such file
# or directory" in exactly this state.
WS="$(cd "$(dirname "$0")/../.." && pwd)"
if [ ! -d "$WS/devtools/Tools" ]; then
    echo "stub: devtools missing at $WS/devtools/Tools" >&2
    exit 1
fi
echo "stub: post-install ran against a complete tree"
STUB_EOF
    chmod +x "$dest/.devcontainer/scripts/post_install.sh"
    [ -n "${SHIM_COUNT_FILE:-}" ] && echo "$(( $(cat "$SHIM_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))" > "$SHIM_COUNT_FILE"
    [ -n "${SHIM_STARTED_FILE:-}" ] && touch "$SHIM_STARTED_FILE"
    while [ ! -e "${SHIM_RELEASE_FILE:-/nonexistent}" ]; do /bin/sleep 0.05; done
    # The rest of the tree arrives: the submodule lands, so the stub succeeds.
    mkdir -p "$dest/devtools/Tools"
    exit 0 ;;
  *)
    echo "shim: unknown SHIM_MODE '${SHIM_MODE:-}'" >&2
    exit 99 ;;
esac
SHIM_EOF
cat > "$SHIM/sleep" <<'SHIM_EOF'
#!/usr/bin/env bash
exit 0
SHIM_EOF
chmod +x "$SHIM/git" "$SHIM/sleep"

OUT=""
RC=0
run() { # <shim-mode> <lifecycle> <workspace-dir>
  RC=0
  OUT="$(SHIM_MODE="$1" PATH="$SHIM:$PATH" WORKSPACE_DIR="$3" WORKSPACE_REPO_URL="$URL" \
         WORKSPACE_BOOTSTRAP_LOCK="$3.lock" WORKSPACE_BOOTSTRAP_FLAG="$3.flag" \
         SHIM_COUNT_FILE="$3.count" \
         bash "$BOOTSTRAP" "$2" 2>&1)" || RC=$?
}
contains() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
fresh_ws() { local ws="$TMP/$1"; rm -rf "$ws"; mkdir -p "$ws"; echo "$ws"; }

# --- 1. the clone cannot fall back to an interactive prompt -----------------
ws="$(fresh_ws ws-env)"
run envcheck create "$ws"
contains "GIT_TERMINAL_PROMPT=[0]" || fail "clone ran without GIT_TERMINAL_PROMPT=0 — it can still hang"
echo "ok 1 - the clone runs with git's interactive prompt disabled"

# --- 2. a failed populate exits non-zero, in BOTH lifecycle phases ----------
# The regression guard: exit 0 here was deliberate once, and it is what let a
# silent hang and a healthy boot look identical to `devcontainer up`.
ws="$(fresh_ws ws-create)"
run noauth create "$ws"
[ "$RC" -ne 0 ] || fail "create phase exited 0 after a failed clone"
[ -z "$(ls -A "$ws")" ] || fail "failed clone left debris in the workspace"
ws="$(fresh_ws ws-start)"
run noauth start "$ws"
[ "$RC" -ne 0 ] || fail "start phase exited 0 after a failed clone"
echo "ok 2 - a populate that never succeeded exits non-zero in create and start"

# --- 3. the failure names the repo and says the next start retries ----------
contains "$URL" || fail "failure message does not name the repo it tried"
contains "next container start retries" || fail "failure message does not say the populate is retried"
echo "ok 3 - the failure names the repo and points at the retry"

# --- 4. missing credentials gets credentials advice -------------------------
ws="$(fresh_ws ws-noauth)"
run noauth create "$ws"
# The literal must carry --with-token: the bare `gh auth login` this once asserted
# is a substring of the token form, so the old assertion passed either wording and
# could not tell the device-flow advice from its replacement.
contains "gh auth login --with-token" || fail "credentials advice does not hand gh a token on stdin"
contains "device flow" || fail "credentials advice does not name the device-flow anti-pattern"
contains "GH_TOKEN" || fail "no scripted-rebuild token recipe in the credentials advice"
contains "Attach an editor" || fail "no editor path in the credentials advice"
echo "ok 4 - a credentials failure gets the three ways forward"

# --- 5. "not found" gets URL-or-access advice, and never asserts which ------
# GitHub answers a private repo the same way whether the URL is wrong or the
# token cannot see it, so advice that picks one sends the reader down a road
# that does not exist.
ws="$(fresh_ws ws-notfound)"
run notfound create "$ws"
contains "WORKSPACE_REPO_URL" || fail "not-found advice does not point at the URL setting"
contains "access" || fail "not-found advice does not raise the access possibility"
! contains "gh auth login" || fail "not-found advice reused the credentials advice — classification did nothing"
echo "ok 5 - a missing repo gets URL-or-access advice, not credentials advice"

# --- 6. anything unrecognized quotes git rather than guessing ---------------
ws="$(fresh_ws ws-weird)"
run weird create "$ws"
contains "Could not resolve host" || fail "unrecognized failure did not quote git's own words"
contains "unrecognized clone failure" || fail "unrecognized failure was not labelled as such"
echo "ok 6 - an unrecognized failure is quoted, not classified"

# --- 7. the success path still populates and hands off ----------------------
# Also the regression guard for the empty PROGRESS array: stderr is captured
# here, so the array is empty, and `set -u` is unforgiving about that.
ws="$(fresh_ws ws-ok)"
run ok create "$ws"
[ "$RC" -eq 0 ] || fail "success path exited $RC"
[ -d "$ws/.git" ] || fail "success path left no .git"
[ -f "$ws/.git/devcontainer-post-install-done" ] || fail "success path never handed off to post_install"
contains "Clone complete" || fail "success path did not report a completed clone"
echo "ok 7 - a working clone populates the workspace and runs the handoff"

# --- 8. an already-populated workspace is never re-cloned -------------------
# noauth would fail the run if a clone were attempted at all, so exit 0 here is
# the proof that none was. A populated workspace is one with the populate-complete
# marker (a .git-only workspace is the legacy state — see test 10, which asserts
# it gets the marker backfilled rather than re-cloned).
ws="$(fresh_ws ws-populated)"
mkdir -p "$ws/.git"
touch "$ws/.git/devcontainer-populate-done"
run noauth start "$ws"
[ "$RC" -eq 0 ] || fail "start phase re-cloned an already-populated workspace"
echo "ok 8 - a populated workspace is left alone"

# Background invocation in its own session (setsid) so the interrupt test can
# SIGKILL the whole clone tree without touching the test's own process group.
# Lock/flag/count paths follow the same per-workspace convention as run().
# Launched inline (not via a helper): $! must name a child of THIS shell so
# `wait` below can reap it — a command substitution would orphan the job.
launch_bg() { # <shim-mode> <lifecycle> <ws> <started-file> <release-file> <out-file>
  local mode="$1" lc="$2" ws="$3" started="$4" release="$5" out="$6"
  setsid env SHIM_MODE="$mode" PATH="$SHIM:$PATH" WORKSPACE_DIR="$ws" WORKSPACE_REPO_URL="$URL" \
       WORKSPACE_BOOTSTRAP_LOCK="$ws.lock" WORKSPACE_BOOTSTRAP_FLAG="$ws.flag" \
       SHIM_STARTED_FILE="$started" SHIM_RELEASE_FILE="$release" SHIM_COUNT_FILE="$ws.count" \
       bash "$BOOTSTRAP" "$lc" > "$out" 2>&1 &
  echo $!
}

# --- 9. two concurrent invocations: one populate, zero failures -------------
# AC 1/4: the winner's slow clone is held mid-flight (its shim blocks on the
# release file) while the loser starts; the loser must wait on the lock rather
# than run post-install against the half-cloned tree. Pre-fix the loser sees
# .git, treats the tree as populated, and runs the stub against it — the stub
# exits non-zero (devtools absent), so the loser fails: the 127 reproduced.
ws="$(fresh_ws ws-race)"
started="$TMP/race.started"; release="$TMP/race.release"
out1="$TMP/race.out1"; out2="$TMP/race.out2"
rm -f "$started" "$release" "$out1" "$out2"
# A failing assertion below must not strand the blocked winner: release it on exit.
trap 'touch "$release" 2>/dev/null || true' EXIT
launch_bg slow create "$ws" "$started" "$release" "$out1" > "$TMP/race.pid1"
pid1="$(cat "$TMP/race.pid1")"
while [ ! -e "$started" ]; do :; done
launch_bg ok create "$ws" "$started" "$release" "$out2" > "$TMP/race.pid2"
pid2="$(cat "$TMP/race.pid2")"
# Deterministic handoff: hold the winner until the loser has actually observed
# the in-progress state (its message appears in its output), so the assertion
# below is never racing the winner's completion. Stop early if the loser died
# first — pre-fix it sees .git mid-clone and fails against the half-tree.
n=0
while ! grep -q "Populate already in progress" "$out2" 2>/dev/null && kill -0 "$pid2" 2>/dev/null; do
    [ "$n" -lt 5000 ] || break
    n=$((n + 1))
done
touch "$release"
OUT="$(cat "$out2")"
contains "Populate already in progress" || fail "loser did not report the in-progress populate"
rc1=0; rc2=0
wait "$pid1" || rc1=$?
wait "$pid2" || rc2=$?
[ "$rc1" -eq 0 ] || fail "first invocation exited $rc1: $(cat "$out1")"
[ "$rc2" -eq 0 ] || fail "loser exited $rc2: $(cat "$out2")"
OUT="$(cat "$out2")"
contains "Populate already in progress" || fail "loser did not report the in-progress populate"
[ "$(cat "$ws.count")" -eq 1 ] || fail "expected exactly one clone, saw $(cat "$ws.count")"
[ -f "$ws/.git/devcontainer-populate-done" ] || fail "populate-complete marker not written"
[ -f "$ws/.git/devcontainer-post-install-done" ] || fail "post-install marker not written"
echo "ok 9 - concurrent invocations produce one populate and zero failures"

# --- 10. a populate interrupted mid-clone is recovered, not mistaken for done --
# AC 2: SIGKILL the bootstrap mid-clone (the whole session, so no shim is left
# spinning). The flag survives the crash; the next invocation must clear the
# debris and re-clone rather than treating the .git-present tree as populated.
# Pre-fix there is no flag and the next invocation runs the stub against the
# broken tree — it fails (devtools absent), and no populate marker is written.
ws="$(fresh_ws ws-int)"
started="$TMP/int.started"; release="$TMP/int.release"
out="$TMP/int.out"; out2="$TMP/int.out2"
rm -f "$started" "$release" "$out" "$out2"
trap 'touch "$release" 2>/dev/null || true' EXIT
launch_bg slow create "$ws" "$started" "$release" "$out" > "$TMP/int.pid"
pid="$(cat "$TMP/int.pid")"
while [ ! -e "$started" ]; do :; done
[ -d "$ws/.git" ] || fail "no .git mid-clone"
[ -f "$ws/.devcontainer/scripts/post_install.sh" ] || fail "no wrapper stub mid-clone"
[ -e "$ws.flag" ] || fail "in-progress flag not written before the clone"
kill -9 -- "-$pid" 2>/dev/null || true
run ok create "$ws"
[ "$RC" -eq 0 ] || fail "recovery invocation exited $RC: $OUT"
[ -f "$ws/.git/devcontainer-populate-done" ] || fail "recovery did not write the populate marker"
[ "$(cat "$ws.count")" -eq 2 ] || fail "expected 2 clones (interrupted + recovery), saw $(cat "$ws.count")"
echo "ok 10 - an interrupted populate is cleared and re-cloned by the next invocation"

# --- 11. a .git-only workspace is a legacy volume: backfill, never wipe ------
# AC 2 (legacy side): a migrated fleet volume carries .git but no flag — it was
# populated by docker cp, not by this bootstrap. The marker must be backfilled
# and the tree left alone; a re-clone would destroy the gitignored state (.env,
# secrets, PHI). noauth would fail any clone attempt, so exit 0 proves none ran.
ws="$(fresh_ws ws-legacy)"
mkdir -p "$ws/.git"
echo "keepme" > "$ws/.env"
run noauth create "$ws"
[ "$RC" -eq 0 ] || fail "legacy workspace failed to backfill"
[ -f "$ws/.git/devcontainer-populate-done" ] || fail "legacy workspace was not backfilled"
[ -f "$ws/.env" ] || fail "legacy workspace was wiped"
echo "ok 11 - a legacy populated volume is backfilled, never re-cloned"

echo "all workspace-bootstrap tests passed"
