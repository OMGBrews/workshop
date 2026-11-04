#!/usr/bin/env bash
# Tests for Tools/devcontainer/update-harnesses.sh — the one command that updates every
# coding harness the devcontainer kit installs.
#
# The contract, asserted here:
#   1. every harness current  → exit 0, each reported `already-current`;
#   2. a real update          → reported `updated`, distinct from already-current;
#   3. a MISSING harness      → `unavailable`, exit NON-ZERO, naming the harness;
#   4. a FAILING update       → `failed`, exit NON-ZERO, naming the harness;
#   5. one harness failing does not stop the run — all three are still reported;
#   6. it is safe to run repeatedly — a second run over the same state agrees;
#   7. an updater that prints an error but exits 0 is NOT reported as failed
#      (the exit code is the classifier, and this pins that choice down);
#   8. every build/harness-*.sh has a row in the updater's HARNESSES table.
#
# TESTS 3 and 4 are the ones that matter, and they are the acceptance criterion's
# "a failure case that would catch a missing harness rather than reporting a false
# success". An updater that visited three tools and exited 0 because the one it could
# not find was skipped is the decorative check docs/signal-hygiene.md is about: its pass
# state is reachable by the exact failure it exists to detect.
#
# TEST 8 is the pairing check. The install side (build/harness-*.sh) and the update side
# (this script's table) are two lists that must name the same harnesses, and nothing in
# the code makes them one — so a harness added to the kit and forgotten here would be
# installed at build time and silently never updated. Asserted rather than remembered.
#
# Everything runs against STUB binaries in a scratch HOME. Real updaters would need a
# network, would take minutes, and — for the failure cases — cannot be asked to fail on
# demand.
set -euo pipefail

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATER="$WORKSHOP_ROOT/Tools/devcontainer/update-harnesses.sh"
BUILD_DIR="$WORKSHOP_ROOT/Tools/devcontainer/build"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${OUT:-}" ] && printf '%s\n' "--- output ---" "$OUT" >&2; exit 1; }

# stub <name> <exit code> <stdout text> — a fake harness binary in $BIN.
#
# It ignores its arguments, so `claude update` and `claude --version` behave alike; the
# updater only ever invokes the update subcommand.
stub() {
  local name="$1" rc="$2" text="$3"
  cat > "$BIN/$name" <<EOF
#!/bin/sh
printf '%s\n' "$text"
exit $rc
EOF
  chmod +x "$BIN/$name"
}

# run_updater — invoke the updater in the sandboxed environment. Captures output and
# exit code without a pipeline, so the status read below is the updater's own.
run_updater() {
  OUT=""
  set +e
  OUT="$(env -i \
        HOME="$SCRATCH_HOME" \
        PATH="$BIN:/usr/bin:/bin" \
        bash "$UPDATER" 2>&1)"
  RC=$?
  set -e
}

# fresh_env — a scratch HOME and an empty stub bin, so no test inherits another's state
# or the real container's harnesses. HOME matters as much as PATH: the updater also
# looks in ~/.local/bin and friends, which is where the real ones actually live.
fresh_env() {
  SCRATCH_HOME="$WORK/home.$1"
  BIN="$WORK/bin.$1"
  mkdir -p "$SCRATCH_HOME" "$BIN"
}

# ---------------------------------------------------------------------------
echo "TEST 1: every harness already current → exit 0"
fresh_env 1
stub claude 0 "Claude Code is already up to date (2.1.0)"
stub omp    0 "omp is already up to date"
stub codex  0 "You are already on the latest version"
run_updater
[ "$RC" -eq 0 ] || fail "expected exit 0 when all three are current, got $RC"
for label in "Claude Code" "Oh My Pi" "Codex"; do
  printf '%s' "$OUT" | grep -q "already-current *$label" \
    || fail "expected '$label' reported already-current"
done

# ---------------------------------------------------------------------------
echo "TEST 2: a real update is distinguished from already-current"
fresh_env 2
stub claude 0 "Installed Claude Code 2.2.0"
stub omp    0 "omp is already up to date"
stub codex  0 "already up to date"
run_updater
[ "$RC" -eq 0 ] || fail "expected exit 0 when an update succeeds, got $RC"
printf '%s' "$OUT" | grep -q "^  updated  *Claude Code" \
  || fail "expected Claude Code reported updated"
printf '%s' "$OUT" | grep -q "already-current *Oh My Pi" \
  || fail "expected Oh My Pi reported already-current alongside the update"

# ---------------------------------------------------------------------------
echo "TEST 3: a MISSING harness is unavailable and exits non-zero"
fresh_env 3
stub claude 0 "already up to date"
stub omp    0 "already up to date"
# codex deliberately absent
run_updater
[ "$RC" -ne 0 ] || fail "a missing harness must exit non-zero — 'cannot be performed' is not a pass"
printf '%s' "$OUT" | grep -q "unavailable *Codex" \
  || fail "expected the missing harness named as unavailable; got no 'unavailable Codex' row"
printf '%s' "$OUT" | grep -q "already-current *Claude Code" \
  || fail "a missing harness must not stop the others being reported"
printf '%s' "$OUT" | grep -qi "setup.sh" \
  || fail "an unavailable harness must print the remedy beside the result"

# ---------------------------------------------------------------------------
echo "TEST 4: a FAILING update is failed and exits non-zero, naming the harness"
fresh_env 4
stub claude 0 "already up to date"
stub omp    1 "error: could not reach the release server"
stub codex  0 "already up to date"
run_updater
[ "$RC" -ne 0 ] || fail "a failed update must exit non-zero, got $RC"
printf '%s' "$OUT" | grep -q "^  failed  *Oh My Pi" \
  || fail "expected the failing harness named in the result table"
printf '%s' "$OUT" | grep -q "could not reach the release server" \
  || fail "expected the failing updater's own output surfaced, not swallowed"

# ---------------------------------------------------------------------------
echo "TEST 5: one failure does not hide the other two"
fresh_env 5
stub claude 1 "boom"
stub omp    0 "already up to date"
stub codex  0 "Installed Codex 1.2.3"
run_updater
[ "$RC" -ne 0 ] || fail "expected non-zero, got $RC"
printf '%s' "$OUT" | grep -q "^  failed  *Claude Code"     || fail "Claude Code should be failed"
printf '%s' "$OUT" | grep -q "already-current *Oh My Pi"   || fail "Oh My Pi should still be reported"
printf '%s' "$OUT" | grep -q "^  updated  *Codex"          || fail "Codex should still be reported"

# ---------------------------------------------------------------------------
echo "TEST 6: safe to run repeatedly — a second run over the same state agrees"
fresh_env 6
stub claude 0 "already up to date"
stub omp    0 "already up to date"
stub codex  0 "already up to date"
run_updater
first="$OUT"; first_rc="$RC"
run_updater
[ "$RC" -eq "$first_rc" ] || fail "repeat run changed the exit code ($first_rc then $RC)"
[ "$OUT" = "$first" ]     || fail "repeat run over unchanged state produced different output"

# ---------------------------------------------------------------------------
echo "TEST 7: an updater that prints an error but exits 0 is not called failed"
fresh_env 7
stub claude 0 "warning: error parsing changelog; nothing to do, already up to date"
stub omp    0 "already up to date"
stub codex  0 "already up to date"
run_updater
[ "$RC" -eq 0 ] || fail "exit 0 from every updater must mean exit 0 overall, got $RC"
printf '%s' "$OUT" | grep -q "^  failed" \
  && fail "a zero exit must never be classified failed — the exit code is the classifier"

# ---------------------------------------------------------------------------
echo "TEST 8: every build/harness-*.sh has a row in the updater's table"
for harness in "$BUILD_DIR"/harness-*.sh; do
  name="$(basename "$harness" .sh)"
  name="${name#harness-}"
  grep -q "^    \"$name|" "$UPDATER" \
    || fail "build/harness-$name.sh installs a harness the updater never visits — add a '$name|…' row to HARNESSES"
done

echo "PASS: update-harnesses.sh"
