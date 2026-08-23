#!/usr/bin/env bash
# Autonomous task-queue loop with per-task worktree isolation.
#
# Each iteration:
#   1. Claims the first eligible queued task that no sibling runner
#      currently holds (non-blocking flock per task slug). Eligibility
#      and order come from each brief's YAML frontmatter: tasks whose
#      `dependencies:` are not yet merged to main are skipped, and the
#      survivors are ordered by `priority:` (high → medium → low), then
#      alphabetically.
#   2. Creates a dedicated git worktree at .task-queue/worktrees/<slug>/
#      on branch task-queue/<slug>, branched off local main.
#   3. Symlinks shared gitignored deps (.env, .venv, node_modules, data/) so
#      the worker can run tests/evals immediately.
#   4. Spawns a fresh `claude` inside the worktree. The worker is told its
#      task path via TASK_QUEUE_TASK_PATH, so it does NOT pick from a list
#      — the runner pre-picks for it.
#   5. On clean worker exit with new commits, validates the worker's
#      reported success against tracked state (validate_worker_state),
#      then merges the task branch into main with `git merge --no-ff`
#      and removes the worktree and branch.
#   6. On crash, timeout, merge conflict, or success-signal disagreement,
#      marks the queue file with a suffix (.crashed / .merge-failed /
#      .abandoned-wip / .partial) and keeps the worktree mounted for
#      human forensics.
#
# Between iterations (including idle polling), a time-gated CI auto-fix
# scan polls GitHub's checks API for recent `task-queue: merge` commits
# and, when a merge's post-push CI failed, commits a follow-up brief
# (fix-ci-<slug>-<fp8>.md) into the queue. A failure fingerprint that
# recurs after bounded retries escalates to a .ci-stuck marker. See
# ci_autofix_scan and the README's "CI auto-fix loop" section.
#
# Parallel runners: launch this script in N terminals at once and the
# runners cooperate. Task pickup is a non-blocking flock per task slug
# (claim_next_task), so each runner claims a different task and walks
# past tasks a sibling already holds. Every write to `main` — merges,
# autostash push/pop, marker-rename commits — is serialized through one
# host-wide lock (acquire_main_lock) so concurrent runners cannot corrupt
# main's index. Worker runs themselves are fully parallel; only the
# few-seconds merge is serialized. See docs/procedures/development/task-queue.md.
#
# The main working tree on `main` stays clean throughout — the user can
# work on other things in parallel.
#
# Lifecycle (mirrored in audit-queue/run.sh — keep the two in sync):
#   - Launch detaches. The runner re-execs itself under `setsid script`
#     so it outlives the terminal it was launched from; stdout is
#     captured to .task-queue/runner-<ts>.out. `--foreground` opts out
#     (runs in the launching terminal, for debugging the runner itself).
#   - Graceful stop. `run.sh stop` touches the global .task-queue/stop
#     sentinel — every parallel runner sees it at its next iteration
#     boundary and exits cleanly. One SIGINT/SIGTERM to a single runner
#     does the same for just that runner. The signal handler only
#     RECORDS the request; the loop finishes the current iteration —
#     merge and cleanup included — then exits at the boundary. It never
#     exits mid-merge or mid-wait_for_bg_session.
#   - Fast stop. A second SIGINT/SIGTERM escalates: the in-flight worker
#     is `claude stop`ped instead of waited on, and the runner exits.
#   - Reconcile on launch. Every task-queue/* branch ahead of main whose
#     per-slug claim lock is free (no live runner behind it) is an
#     orphan — a crash-interrupted run that may already be complete.
#     Launch reports orphans; `run.sh recover` merges and cleans them up.
#
# Subcommands: `run.sh stop`, `run.sh recover`, `run.sh --help`.

set -u

# Resolve the repo root from the script's own location, WITHOUT resolving
# symlinks. In consuming repos this script is reached through a per-skill
# symlink (.agents/skills/task-queue -> .../devtools/.agents/skills/task-queue,
# and .claude/skills/task-queue -> ../../.agents/skills/task-queue beside it),
# and any physical resolution — `git -C` chdirs before it answers, so it
# reports the *devtools* toplevel — would aim the runner at devtools' (empty)
# queue instead of the mounting repo's. Bash's `cd`/`pwd` are logical by
# default, so walking three levels up from the invocation path
# (<root>/.agents/skills/task-queue or <root>/.claude/skills/task-queue --
# both are three deep) yields the mounting repo's root for symlinked,
# vendored, and native layouts alike.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
if ! ROOT_TOPLEVEL="$(git -C "$ROOT" rev-parse --show-toplevel)"; then
  echo "[task-queue] error: resolved repo root '$ROOT' is not a readable Git worktree; no repository root could be discovered" >&2
  exit 1
fi
if [[ "$ROOT_TOPLEVEL" != "$ROOT" ]]; then
  echo "[task-queue] error: resolved repo root '$ROOT' is not the Git worktree root; Git reports enclosing toplevel '$ROOT_TOPLEVEL'" >&2
  echo "[task-queue] invoke from that repository instead: bash $ROOT_TOPLEVEL/.agents/skills/task-queue/run.sh" >&2
  exit 1
fi
if ! ROOT_SUPERPROJECT="$(git -C "$ROOT" rev-parse --show-superproject-working-tree)"; then
  echo "[task-queue] error: resolved repo root '$ROOT' could not be classified as a top-level Git worktree" >&2
  exit 1
fi
if [[ -n "$ROOT_SUPERPROJECT" ]]; then
  echo "[task-queue] error: resolved repo root '$ROOT' is a submodule of '$ROOT_SUPERPROJECT', not a supported top-level worktree" >&2
  echo "[task-queue] invoke from the mounting repository instead: bash $ROOT_SUPERPROJECT/.agents/skills/task-queue/run.sh" >&2
  exit 1
fi
# Tasks root: docs/work/tasks/ is the machine-owned location, same for every repo.
TASKS_REL="docs/work/tasks"
QUEUE_REL="$TASKS_REL/queued"
QUEUE_DIR="$ROOT/$QUEUE_REL"
BLOCKED_DIR="$QUEUE_DIR/blocked"
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT_FILE="$SKILL_DIR/initial-prompt.md"
# Absolute path to the worker's self-termination script. Passed to the worker
# via the TASK_QUEUE_SELF_TERMINATE env var (see below) so the worker runs the
# script byte-for-byte rather than reproducing it from the prompt — see
# "Self-termination" in this skill's README.md.
SELF_TERMINATE_SCRIPT="$SKILL_DIR/self-terminate.sh"
# Absolute path to this script — used by the detach re-exec and by the
# `stop` / `recover` hints, so they are correct regardless of the cwd or
# the (possibly relative) path the operator launched the runner with.
SELF="$SKILL_DIR/run.sh"
STATE_DIR="$ROOT/.task-queue"
# Global graceful-stop sentinel. `run.sh stop` touches this file; every
# parallel runner of this queue observes it at its next iteration
# boundary and exits cleanly. One sentinel per queue — not per-runner
# (per-runner stops use a SIGINT/SIGTERM to that runner's pid). A fresh
# launch clears any stale sentinel; a runner that is itself stopping
# leaves it in place so sibling runners still draining also see it.
STOP_SENTINEL="$STATE_DIR/stop"
LOG_DIR="$STATE_DIR/logs"
LOCK_DIR="$STATE_DIR/locks"
WORKTREE_DIR="$STATE_DIR/worktrees"
# Host-wide lock file serializing every mutation of `main` (merges,
# autostash push/pop, marker-rename commits) across all task-queue
# runners on this host. See acquire_main_lock / release_main_lock.
MAIN_LOCK_FILE="$LOCK_DIR/main.lock"
# Per-task hard timeout. Empty by default — the realistic operating mode
# is phone-mediated dialog where the worker may legitimately wait hours
# on a single AskUserQuestion call. Set TASK_QUEUE_TIMEOUT (e.g. "60m",
# "2h") to opt back into a kill ceiling. Stuck workers can be recovered
# manually via Ctrl+C on the runner.
TASK_TIMEOUT="${TASK_QUEUE_TIMEOUT:-}"
# Clarification-dialog grace, in seconds. When the user DECLINES an
# AskUserQuestion to chat in free text, the worker drops to a plain-text
# question and ends its turn as state=blocked tempo=blocked — structurally
# identical to a finished task (see worker_in_clarification_dialog). We hold
# the session open this long after the human's last activity so they can type
# their reply; an abandoned dialog still closes out once the window lapses.
# Override with TASK_QUEUE_CLARIFY_GRACE_S.
CLARIFY_GRACE_S="${TASK_QUEUE_CLARIFY_GRACE_S:-600}"
POLL_SECONDS="${TASK_QUEUE_POLL_SECONDS:-5}"
# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Log prefix for the mirrored helpers below. The two runners' helper
# bodies are asserted byte-identical (test-run.sh), so anything they
# print has to reach the tag through a variable rather than a literal.
LOG_TAG="task-queue"
# One-shot flag so a missing/renamed daemon `inFlight` field is reported
# once per runner instead of on every 5s poll. See worker_bg_task_count.
INFLIGHT_UNAVAILABLE_LOGGED=0
# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Bookkeeping for the current background-work episode: the epoch it opened
# (0 = no episode open), how many polls it has spanned, and how many of those
# were at tempo=idle — the state where the inFlight gate is the only thing
# holding takeover off. Driven by bg_episode_track / bg_episode_close, which
# carry the full rationale. Globals rather than wait_for_bg_session locals so
# test-run.sh can drive the bookkeeping without a daemon.
BG_EPISODE_SINCE=0
BG_EPISODE_POLLS=0
BG_EPISODE_IDLE_POLLS=0
# Ceiling, in seconds, on the background-work hold in wait_for_bg_session's
# state=blocked branch. The hold exists so the runner never takes over a
# worker that ended its turn with a backgrounded command still running.
#
# The ceiling is load-bearing for TWO reasons, and the second is routine —
# do not delete this as an obsolete workaround for an old daemon bug:
#
#   1. The counter LEAKS. A 2026-07-22 worker session (Claude Code 2.1.217)
#      reached state=done still reporting `{"tasks": 28}` after 45
#      backgrounded Bash calls.
#   2. `inFlight` counts MORE than backgrounded Bash. Observed 2026-07-31 on
#      2.1.220: a worker running a Monitor reported
#      `{"tasks": 2, "kinds": ["local_bash", "monitor"]}`. A *persistent*
#      Monitor keeps the count above zero for the worker's whole session, so
#      "background work is armed" stops being a transient condition.
#
# Either way an unbounded hold would wedge the runner
# on that task forever, which is worse than the race it guards. 15 minutes
# comfortably covers a backgrounded pre-commit gate (observed >10 min on a
# cold hook cache) while capping the damage from a count that never drains.
#
# NOTE: this ceiling bounds ONLY the state=blocked hold. check_stall_signature's
# suppression is bounded separately, by STALL_BG_MAX_S just below. Keep the two
# distinct: they answer different questions from different anchors — this one
# from when the hold started, that one from the worker's last activity.

BG_HOLD_MAX_S="${TASK_QUEUE_BG_HOLD_MAX_S:-900}"
# Ceiling, in seconds, on check_stall_signature's background-work suppression:
# how long a positive inFlight count may go on excusing a silent worker.
#
# Why the suppression needs a bound at all. A positive count is not always a
# transient condition — see reason 2 above: a *persistent* Monitor stays armed
# for the worker's whole session. The daemon does not move a hung session to a
# terminal state either (measured 2026-07-31 on 2.1.220 by
# probe-persistent-inflight.sh: a Monitor-armed session sat at state=working
# tempo=idle across 281s of unbroken quiet, tasks never dropping below 1 and
# the state never transitioning). In that state
# check_stall_signature is the ONLY recovery path — wait_for_bg_session's
# done/failed/stopped branches never fire and its blocked branch, with
# BG_HOLD_MAX_S in it, is never reached — and TASK_QUEUE_TIMEOUT is empty by
# default. An unbounded suppression therefore wedges the runner on that task
# for good.
#
# Anchored on worker ACTIVITY, not on when the count went positive: the bound
# is compared against worker_quiet_seconds, so any real work the worker does
# resets it and only genuine silence accumulates. 30 minutes is ~3x the
# observed >10-min cold-cache pre-commit gate. Err generous — crossing this
# bound stops a worker that may be alive, which is the 2026-07-31 incident
# again, while the only alternative on the other side is waiting forever.
STALL_BG_MAX_S="${TASK_QUEUE_STALL_BG_MAX_S:-1800}"
# Worker model and effort. Without an explicit --model the daemon-spawned
# worker inherits the operator's saved interactive default, which is not a
# deliberate choice for autonomous execution (observed 2026-07-31: workers
# came up on the model /model had last saved). Task briefs are prepared by
# /task-finalize on the strongest model; workers execute them on Opus at
# xhigh effort by default. Override with TASK_QUEUE_MODEL / TASK_QUEUE_EFFORT;
# set either to the empty string to fall back to inheriting the default.
WORKER_MODEL="${TASK_QUEUE_MODEL:-opus}"
WORKER_EFFORT="${TASK_QUEUE_EFFORT:-xhigh}"

# ---- CI auto-fix loop config ------------------------------------------
# Between iterations of the pickup loop the runner polls GitHub's checks
# API for recent `task-queue: merge <slug>` commits on main and, when a
# merge's CI failed, commits a follow-up task brief into the queue
# (fix-ci-<slug>-<fp8>.md) so the next worker fixes it. A failure
# fingerprint that recurs after CI_FIX_MAX_ATTEMPTS follow-ups escalates:
# the brief is committed with a `.ci-stuck.<ts>.md` marker name (skipped
# by pickup) and a STUCK file is written under .task-queue/. See
# ci_autofix_scan below and the skill README's "CI auto-fix loop" section.
#
# Scans are time-gated (default every 120s; 0 disables) and require gh,
# jq, and an `origin` remote — when any is missing the scan disables
# itself with a single log line. Commits that aren't on the remote yet
# (nothing is auto-pushed) simply stay pending until the user pushes.
CI_SCAN_INTERVAL_S="${TASK_QUEUE_CI_SCAN_SECONDS:-120}"
CI_FIX_MAX_ATTEMPTS="${TASK_QUEUE_CI_FIX_MAX_ATTEMPTS:-2}"
CI_MERGE_SCAN_LIMIT="${TASK_QUEUE_CI_SCAN_COMMITS:-20}"
# A pushed commit with zero check runs is only concluded "no CI" after
# this grace (seconds) — checks can take a while to attach after a push.
CI_ZERO_CHECK_GRACE_S="${TASK_QUEUE_CI_ZERO_CHECK_GRACE_S:-3600}"
CI_STATE_DIR="$STATE_DIR/ci"
CI_CHECKED_DIR="$CI_STATE_DIR/checked"        # one file per verdict-reached merge sha
CI_FP_DIR="$CI_STATE_DIR/fingerprints"        # <fp>.count / <fp>.escalated
CI_FORMATTER="$SKILL_DIR/format_ci_failure.py"
CI_LAST_SCAN_EPOCH=0
CI_UNAVAILABLE_LOGGED=0

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Directories on the main tree that should be visible from each worktree.
# Symlinked into the new worktree before the worker spawns. Everything here
# is gitignored at root, so the symlinks themselves are also gitignored
# inside the worktree.
SHARED_PATHS=(
  ".env"
  ".secrets"
  ".venv"
  "app/frontend/node_modules"
  "data"
)
# Repos can extend the list via .task-queue-shared-paths at the repo root
# (one path per line, `#` comments allowed). Missing paths are skipped at
# staging time either way, so the defaults are harmless in repos that
# lack them.
if [[ -f "$ROOT/.task-queue-shared-paths" ]]; then
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    SHARED_PATHS+=("$p")
  done < "$ROOT/.task-queue-shared-paths"
fi

mkdir -p "$QUEUE_DIR" "$BLOCKED_DIR" "$LOG_DIR" "$LOCK_DIR" "$WORKTREE_DIR" \
  "$CI_CHECKED_DIR" "$CI_FP_DIR"

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# ---- Graceful / fast stop --------------------------------------------
# The signal handler REQUESTS a stop; it never performs the exit itself.
# A handler that `exit`ed would tear the runner down at whatever
# arbitrary point the signal interrupted — mid-merge, mid-poll — which
# is exactly the orphaned-branch failure this lifecycle was built to
# close. Instead the handler sets a flag and returns; the loop checks
# the flag at its iteration boundary (should_stop) and exits there.
STOP_REQUESTED=0
FAST_STOP=0
# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Set by wait_for_bg_session when it observes the daemon's Continue
# auto-respawn going unanswered (see check_stall_signature). The
# success-path branch reads it to decide whether to run the queue-
# file `git rm` on the worker's behalf before merging. Reset at the
# start of each wait_for_bg_session call.
STALL_FORCED=0

# First INT/TERM/HUP records a graceful stop; a second escalates to a
# fast stop, where the in-flight worker is `claude stop`ped rather than
# waited on (see wait_for_bg_session).
request_stop() {
  if (( STOP_REQUESTED )); then
    if (( FAST_STOP == 0 )); then
      FAST_STOP=1
      echo
      echo "[task-queue] second stop request — fast stop: abandoning the in-flight worker"
    fi
  else
    STOP_REQUESTED=1
    echo
    echo "[task-queue] stop requested — finishing the current iteration, then exiting"
    echo "[task-queue] (signal again to fast-stop and abandon the in-flight worker)"
  fi
}

# True at an iteration boundary when a stop is pending — via this
# runner's own signal flag or the global stop sentinel touched by
# `run.sh stop`.
should_stop() {
  (( STOP_REQUESTED )) && return 0
  [[ -f "$STOP_SENTINEL" ]] && return 0
  return 1
}

# ---- Frontmatter-driven eligibility ----------------------------------
# Task briefs carry a YAML frontmatter block (status / effort / priority /
# dependencies — see the canonical template, .agents/skills/task-create/_TEMPLATE.md). The claim path
# reads two of those fields:
#   priority:      high | medium | low — claim order (default medium when
#                  absent or unrecognised, so a malformed brief is still
#                  claimable rather than silently stuck).
#   dependencies:  list of task slugs that must merge to main first. A
#                  strict DAG, not a hint — see task_deps_satisfied.
#
# The three *_at_head / *_on_main functions below are the git-query
# boundaries (stubbed by test-run.sh); everything else is pure parsing.

# Echo the YAML frontmatter block (the lines between the opening and
# closing `---` fences) of a queue file at main's HEAD. Echoes nothing
# when the file has no frontmatter.
task_frontmatter_at_head() {
  local rel="$1"
  git -C "$ROOT" show "HEAD:$rel" 2>/dev/null \
    | awk 'NR==1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }'
}

# True if any file for this slug — original name, forensic-marker rename,
# or blocked/ — is present in the queued/ tree at main's HEAD. Any such
# presence means the dependency has NOT completed: still queued, in
# flight, crashed, or blocked.
dep_in_queue_tree_at_head() {
  local dep="$1" path
  local q="$QUEUE_REL"
  while IFS= read -r path; do
    case "$path" in
      "$q/$dep.md"|"$q/blocked/$dep.md") return 0 ;;
      "$q/$dep".crashed.*.md|"$q/$dep".merge-failed.*.md) return 0 ;;
      "$q/$dep".abandoned-wip.*.md|"$q/$dep".dispatch-failed.*.md) return 0 ;;
      "$q/$dep".ci-stuck.*.md|"$q/$dep".partial.*.md) return 0 ;;
    esac
  done < <(git -C "$ROOT" ls-tree -r --name-only HEAD "$QUEUE_REL/" 2>/dev/null)
  return 1
}

# True if a brief for this slug has ever existed at its queued/ path in
# main's history. Distinguishes "completed and removed" from "never
# queued at all" (e.g. a typo'd slug, or a task still sitting in
# now/soon/later) — the latter must block dependents.
dep_was_queued_on_main() {
  local dep="$1"
  [[ -n "$(git -C "$ROOT" rev-list -1 HEAD -- "$QUEUE_REL/$dep.md" 2>/dev/null)" ]]
}

# Echo the value of a scalar frontmatter field (first match), stripped of
# quotes, surrounding whitespace, and trailing comments. Frontmatter text
# arrives on stdin.
frontmatter_scalar() {
  local key="$1"
  sed -n "s/^${key}:[[:space:]]*//p" \
    | head -1 \
    | sed 's/[[:space:]]*#.*$//' \
    | tr -d '"'"'" \
    | sed 's/[[:space:]]*$//'
}

# Echo a sort rank for the task's priority: 0=high, 1=medium, 2=low.
# Absent or unrecognised values rank as medium. Frontmatter on stdin.
task_priority_rank() {
  local p
  p="$(frontmatter_scalar priority | tr '[:upper:]' '[:lower:]')"
  case "$p" in
    high)   echo 0 ;;
    low)    echo 2 ;;
    *)      echo 1 ;;
  esac
}

# Echo the task's dependency slugs, one per line. Supports the inline
# form (`dependencies: []`, `dependencies: [a, b]`) and the block form
# (`dependencies:` followed by `- slug` lines). Frontmatter on stdin.
task_dependencies() {
  awk '
    /^dependencies:[[:space:]]*\[/ {
      line = $0
      sub(/^dependencies:[[:space:]]*\[/, "", line)
      sub(/\].*$/, "", line)
      n = split(line, items, ",")
      for (i = 1; i <= n; i++) {
        gsub(/[[:space:]"'"'"']/, "", items[i])
        if (items[i] != "") print items[i]
      }
      exit
    }
    /^dependencies:[[:space:]]*(#.*)?$/ { in_deps = 1; next }
    in_deps && /^[[:space:]]*-[[:space:]]*/ {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", item)
      sub(/[[:space:]]*#.*$/, "", item)
      gsub(/["'"'"']/, "", item)
      if (item != "") print item
      next
    }
    in_deps { exit }
  '
}

# True if every dependency listed in the frontmatter (stdin) has merged
# to main. A dependency is satisfied only when BOTH hold:
#   1. No file for its slug remains anywhere in the queued/ tree at HEAD
#      (original name, marker rename, or blocked/) — it isn't pending,
#      in flight, crashed, or blocked.
#   2. Its brief existed at the queued/ path at some point in main's
#      history — positive evidence it went through the queue. Without
#      this, a typo'd or never-queued slug would read as satisfied.
# This is a strict DAG: an unsatisfiable dependency blocks its dependents
# forever (visible as the task never being claimed), which is preferred
# over racing ahead of a prerequisite.
task_deps_satisfied() {
  local dep
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if dep_in_queue_tree_at_head "$dep"; then return 1; fi
    if ! dep_was_queued_on_main "$dep"; then return 1; fi
  done < <(task_dependencies)
  return 0
}

# Print every eligible task file (absolute path) at main's HEAD, one per
# line, ordered by frontmatter priority (high → medium → low), then
# alphabetically within a priority. Eligibility is computed from main's
# HEAD — NOT from the filesystem — so that staged-but-uncommitted task
# moves don't race with the runner. The user explicitly hands a task over
# by committing its placement in `queued/`; until
# that commit lands, the runner cannot see it.
#
# Skipped:
#   - README.md
#   - forensic marker files (.crashed / .merge-failed / .abandoned-wip /
#     .dispatch-failed / .ci-stuck / .partial), which the runner itself
#     commits when it can't complete a task (or, for .ci-stuck, when a CI
#     failure fingerprint exhausted its bounded retries). They stay in
#     the tree as a visible signal but are filtered from pickup.
#   - tasks whose frontmatter `dependencies:` are not all merged to main
#     (see task_deps_satisfied).
#
# Prints nothing if no task is claimable.
list_eligible_tasks() {
  local rel fm
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    fm="$(task_frontmatter_at_head "$rel")"
    printf '%s\n' "$fm" | task_deps_satisfied || continue
    printf '%s %s\n' "$(printf '%s\n' "$fm" | task_priority_rank)" "$rel"
  done < <(git -C "$ROOT" ls-tree --name-only HEAD "$QUEUE_REL/" 2>/dev/null \
             | grep -E '\.md$' \
             | grep -v 'README\.md$' \
             | grep -vE '\.(crashed|merge-failed|abandoned-wip|dispatch-failed|ci-stuck|partial)\.[0-9-]+\.md$') \
    | sort \
    | sed -e 's/^[0-9] //' -e "s#^#$ROOT/#"
}

# True if the given task file (absolute path) is still present at main's
# HEAD. claim_next_task calls this after winning a task's lock to close a
# TOCTOU window: a sibling runner may have merged — and so removed — the
# task in the gap between list_eligible_tasks snapshotting HEAD and the
# flock. Holding the lock makes the answer stable: no sibling can be
# working (hence merging) a task whose lock we hold.
task_at_head() {
  local rel="${1#$ROOT/}"
  [[ -n "$(git -C "$ROOT" ls-tree --name-only HEAD -- "$rel" 2>/dev/null)" ]]
}

# Claim the first eligible task that no sibling runner currently holds.
#
# Walks list_eligible_tasks in order and, for each, tries a NON-BLOCKING
# flock on that task's per-slug lock file ($LOCK_DIR/<slug>.lock) on fd 9.
# The first task whose lock we win is claimed: TASK_FILE and SLUG are set
# as globals and fd 9 is left HELD — released only at the bottom of the
# loop body, after the task has merged. Holding fd 9 for the whole task
# is what makes an in-flight task invisible to sibling runners: the task
# stays at main's HEAD until it merges, so list_eligible_tasks keeps
# listing it, and the held lock is the signal that tells siblings to skip
# past it to the next free task.
#
# flock is kernel-atomic and advisory-per-process, so the try-lock IS the
# claim (no check-then-act window), and a crashed runner's locks are
# released automatically by the OS — no stale-lock cleanup is needed.
#
# Returns 0 with TASK_FILE / SLUG set and fd 9 held if a task was claimed;
# 1 with fd 9 closed if every eligible task is already locked or the
# queue is empty.
claim_next_task() {
  local candidate slug lock_file
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    slug="$(slug_from_task_file "$candidate")"
    [[ -z "$slug" ]] && continue
    lock_file="$LOCK_DIR/$slug.lock"
    exec 9>"$lock_file"
    if flock -n 9; then
      # Won the lock. Re-verify the task is still at HEAD before
      # committing to it — see task_at_head for the TOCTOU it closes.
      if task_at_head "$candidate"; then
        TASK_FILE="$candidate"
        SLUG="$slug"
        return 0
      fi
      # Task vanished from HEAD (a sibling merged it) — release and skip.
      exec 9>&-
      continue
    fi
    # Lock held by a sibling runner — drop our (unlocked) fd handle and
    # move on to the next candidate.
    exec 9>&-
  done < <(list_eligible_tasks)
  return 1
}

# Sluggify a task filename (without .md) into a path-safe identifier used
# for the branch name and worktree directory. The queue filenames are
# already kebab-case-ish, but we strip anything weird just in case.
slug_from_task_file() {
  local path="$1"
  local base
  base="$(basename "$path" .md)"
  printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//'
}

# Render the worker prompt: `initial-prompt.md` with every
# `<!-- include: <file>#<anchor> -->` directive replaced by that anchor's
# block from the named sibling file. The five shared execution-discipline
# blocks live in execution-discipline.md so /task-implement can run the same
# discipline in-session; expanding them here keeps the dispatched prompt
# byte-for-byte the text it was when those blocks were inline.
#
# The substitution is a TEXT splice, not a line replacement, because one
# block (definition-of-done) sits mid-paragraph in the prompt: whatever
# precedes the directive on its line stays glued to the block's first line,
# whatever follows stays glued to its last, and the block's interior lines
# take the directive line's own indentation. Blank lines inside a block are
# emitted bare, never indented, so no trailing whitespace appears.
#
# Consequence for authors: a block body in execution-discipline.md is stored
# with the line breaks the *prompt* needs, since nothing re-wraps it. Change
# a block's wrapping and you change the dispatched prompt.
#
# A missing file or unknown anchor exits non-zero with the reason on
# stderr. The caller must halt on that: a silently-dropped include would
# dispatch a worker with a hole where its discipline should be, and
# nothing downstream would notice.
render_worker_prompt() {
  awk -v skill_dir="$SKILL_DIR" '
    match($0, /<!-- include: [^ ]+ -->/) {
      prefix = substr($0, 1, RSTART - 1)
      suffix = substr($0, RSTART + RLENGTH)
      spec = substr($0, RSTART, RLENGTH)
      sub(/^<!-- include: /, "", spec)
      sub(/ -->$/, "", spec)
      indent = $0
      sub(/[^ \t].*$/, "", indent)
      hash = index(spec, "#")
      if (hash == 0) {
        print "render_worker_prompt: include has no #anchor: " spec > "/dev/stderr"
        exit 1
      }
      inc_file = skill_dir "/" substr(spec, 1, hash - 1)
      anchor = substr(spec, hash + 1)
      open_tag = "<!-- block: " anchor " -->"
      close_tag = "<!-- /block: " anchor " -->"
      emitting = 0
      n = 0
      while ((getline inc_line < inc_file) > 0) {
        if (inc_line == close_tag) { emitting = 0; continue }
        if (emitting) { block[++n] = inc_line }
        else if (inc_line == open_tag) { emitting = 1 }
      }
      close(inc_file)
      if (n == 0) {
        print "render_worker_prompt: no content for include " spec > "/dev/stderr"
        exit 1
      }
      for (i = 1; i <= n; i++) {
        if (i == 1) out = prefix block[i]
        else if (block[i] == "") out = ""
        else out = indent block[i]
        if (i == n) out = out suffix
        print out
        delete block[i]
      }
      next
    }
    { print }
  ' "$PROMPT_FILE"
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Create or replace symlinks inside the worktree so the worker can run
# tests/evals without re-installing deps. Only links paths that exist on
# the main tree — missing ones are skipped silently so this works on
# fresh checkouts that haven't built the frontend yet, etc.
stage_shared_paths() {
  local worktree="$1"
  local p src dst dst_parent
  for p in "${SHARED_PATHS[@]}"; do
    src="$ROOT/$p"
    dst="$worktree/$p"
    if [[ ! -e "$src" ]]; then
      continue
    fi
    dst_parent="$(dirname "$dst")"
    mkdir -p "$dst_parent"
    rm -rf "$dst"
    ln -s "$src" "$dst"
  done
}

# Re-entrant host-wide lock guarding every mutation of `main`.
#
# Two or more task-queue runners can work in parallel, but only one may
# touch `main` and its index at a time: concurrent merges, autostash
# push/pop sequences, or marker-rename commits would corrupt the index
# or trample each other's stashes. acquire_main_lock blocks until it
# holds $MAIN_LOCK_FILE (fd 8); release_main_lock drops it.
#
# Re-entrant by design: mark_queue_file takes the lock for its commit,
# but it is also called from inside the already-locked merge block. A
# depth counter (MAIN_LOCK_HELD) makes the inner acquire a no-op bump,
# so the real flock is released only when the outermost holder releases
# — a plain second flock on a fresh fd would self-deadlock against the
# lock this process already holds.
#
# The flock is advisory and tied to fd 8, so a crashed runner releases
# it automatically; no stale-lock recovery is needed.
MAIN_LOCK_HELD=0

acquire_main_lock() {
  if (( MAIN_LOCK_HELD == 0 )); then
    exec 8>"$MAIN_LOCK_FILE"
    flock 8
  fi
  MAIN_LOCK_HELD=$(( MAIN_LOCK_HELD + 1 ))
}

release_main_lock() {
  if (( MAIN_LOCK_HELD > 0 )); then
    MAIN_LOCK_HELD=$(( MAIN_LOCK_HELD - 1 ))
    if (( MAIN_LOCK_HELD == 0 )); then
      flock -u 8
      exec 8>&-
    fi
  fi
}

# Write the forensic-marker stub file (a few lines, deliberately
# dissimilar to a task doc so git's rename detection won't pair the
# original's deletion with it). $1 = absolute marker path,
# $2 = slug basename, $3 = marker label, $4 = timestamp,
# $5 = the forensic record this failure actually wrote (empty when it
# wrote none), $6 = the run log path (may be empty).
#
# $5 is passed in rather than described, because the stub is emitted from
# SIX different merge-failed situations that leave three different kinds
# of record: a $STATE_DIR/STUCK-*.md file, a worker-written
# $WORKTREE/STUCK.md, or nothing at all. The old text hardcoded "See the
# matching STUCK-*.md record under .task-queue/", which was wrong at
# every one of them — the merge-failure record was written into the
# worktree, and three sites write no record whatsoever. A pointer to a
# file that does not exist ends an investigation in the wrong place, so
# "no record was written" is a first-class answer here, not a fallback to
# be tidied away later.
_write_marker_stub() {
  local marker_path="$1" slug="$2" label="$3" ts="$4"
  local record_path="${5:-}" log_path="${6:-}"
  local trailer
  if [[ -n "$record_path" ]]; then
    trailer="See \`$record_path\` (and the run log) for the worktree, branch,
and recovery steps."
  else
    trailer="No forensic record was written for this failure — the run log is the
only forensic trail: \`${log_path:-see .task-queue/logs/}\`."
  fi
  # `git rm` of the slug doc removes the queued/ directory too if it was
  # the last file there; recreate it so the stub write can't fail. (In
  # practice queued/README.md keeps the dir alive — this is belt-and-suspenders.)
  mkdir -p "$(dirname "$marker_path")"
  cat >"$marker_path" <<EOF
# task-queue forensic marker — $label

The task-queue runner could not complete \`$slug.md\` ($label at $ts).
The original task doc was removed; this stub records the forensic state
so the runner's \`queued/\` scan skips the slug instead of re-picking it.

$trailer
EOF
}

# Capture the paths git reported as conflicted by a merge that has just
# failed. MUST be called while that merge's index is still conflicted —
# `git merge --abort` clears the unmerged entries, and a capture taken
# afterwards returns an EMPTY list that reads exactly like "no conflicts
# here", which is the failure mode this function exists to remove. The
# merge-failed record is not written until well after the abort, so the
# value has to be captured early and carried in a variable.
#
# Mirrors the WEDGE_PATHS idiom in the pre-merge wedge gate below, so the
# file gains no new pattern.
capture_conflict_paths() {  # <repo-root>
  local repo="$1" paths
  paths="$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null \
            | sort -u | paste -sd' ' - || true)"
  [[ -z "$paths" ]] && paths="(none reported — see the run log)"
  printf '%s' "$paths"
}

# Write the merge-failure forensic record.
#
# It goes to $STATE_DIR, NOT into the worktree, because its own recovery
# steps tell the reader to `git worktree remove $WORKTREE` — which deleted
# the document they were still reading, before its last step. The sibling
# autostash-pop-conflict path already writes to the state dir for exactly
# this reason.
#
# The conflicting paths lead, ahead of any hypothesis about the cause: on
# 2026-08-07 two merge failures were `modify/delete` conflicts confined to
# the queue directory and touching no code, while the record asserted "a
# real content conflict between the task branch's changes and commits that
# landed on main" — sending the investigation to a code overlap that
# existed and was innocent.
#
# $1 = record path, $2 = branch, $3 = worktree, $4 = original queue-file
# path relative to the repo root, $5 = timestamp, $6 = run log path,
# $7 = conflicting paths (from capture_conflict_paths), $8 = repo root.
write_merge_failed_record() {
  local record_path="$1" branch="$2" worktree="$3" task_rel="$4"
  local ts="$5" log_path="$6" conflict_paths="$7" repo_root="$8"
  mkdir -p "$(dirname "$record_path")"
  cat >"$record_path" <<EOF
# Stuck — merge failed

The task-queue runner could not merge \`$branch\` into \`main\`.

- Conflicting paths: \`$conflict_paths\`
- Worktree: \`$worktree\`
- Branch:   \`$branch\`
- Original queue file: \`$task_rel\` (removed on main; a \`.merge-failed.$ts.md\` stub marker was committed in its place)
- Run log: \`$log_path\`

Read the conflicting paths above before theorising. If they are code
paths, this is most likely a real content conflict between the task
branch's changes and commits that landed on main during the task. If they
are only queue or marker files, it is a bookkeeping collision — the task's
own work is probably fine and unrelated to the failure. (Main's WIP was
autostashed before the merge attempt and has been restored.)

To resolve:
1. Inspect the conflict: \`git diff main...$branch\`
2. \`cd $repo_root && git merge --no-ff $branch\` and resolve conflicts manually
3. \`git worktree remove $worktree && git branch -d $branch\`
4. On main, delete the \`.merge-failed.$ts.md\` stub marker file (the task is done).
5. \`rm $record_path\` once you're done.

(This record lives outside \`$worktree\`, so step 3 does not delete it.)
EOF
}

# Inbound-link repair for the marker commit. Moving the brief off its
# original path breaks every markdown link that still pointed at it, and
# in a repo whose commit gate checks doc links whole-tree the marker
# commit itself fails on exactly those links — the 2026-08-01 wedge,
# where the failure marker for a finished task could not be committed.
# The repair script mechanically rewrites the inbound links
# old-path -> marker-path so they keep resolving, and prints the
# repo-relative paths of the files it rewrote (one per line) so they can
# be staged into the same marker commit.
#
# Existence-guarded: this file is OMG-synced byte-identical (see
# devtools/SYNC.md), while the repair script — like the doc-links gate
# it pairs with — is repo-local. A repo without the script gets the old
# behavior, links left as they were.
_stage_link_repairs() {  # <old-rel-path> <new-rel-path>; sets REPAIRED_FILES
  REPAIRED_FILES=""
  local repair_script="$ROOT/scripts/repair_doc_links.py"
  [[ -f "$repair_script" ]] || return 0
  if ! REPAIRED_FILES="$(cd "$ROOT" && python3 "$repair_script" "$1" "$2" 2>>"${LOG_FILE:-/dev/null}")"; then
    return 1
  fi
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    git -C "$ROOT" add -- "$f" || return 1
  done <<< "$REPAIRED_FILES"
  return 0
}

# Roll back whatever _stage_link_repairs staged (index and worktree).
_restore_link_repairs() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    git -C "$ROOT" restore --source=HEAD --staged --worktree -- "$f" >/dev/null 2>&1 || true
  done <<< "${REPAIRED_FILES:-}"
}

# Record a forensic marker for the queue file AS A COMMIT on main, so
# the next iteration's list_eligible_tasks (which reads HEAD, not the
# filesystem) skips it. Committing is required: a working-tree-only
# change would leave HEAD unchanged and the runner would infinitely
# re-pick the same task.
#
# How the marker is recorded depends on the marker label, because the two
# kinds of forensic marker are recovered differently:
#
#   - "merge-failed": the worker's branch IS complete and will be
#     re-merged on retry. The branch's own final commit *deletes*
#     `<slug>.md`. A content-preserving rename (`git mv <slug>.md
#     <slug>.merge-failed.<ts>.md`) manufactured a guaranteed rename/delete
#     conflict on that retry: git's rename detection pairs main's rename
#     target (the marker) with the branch's deletion and raises a `UD`
#     (rename/delete) conflict on the marker — wedging main (the 2026-06-17
#     incident). So for merge-failed we instead (a) `git rm` the original
#     `<slug>.md`, which MATCHES the branch's own deletion → a clean
#     both-sides-delete on re-merge, and (b) write a FRESH, deliberately
#     dissimilar stub at `<slug>.merge-failed.<ts>.md` so git's rename
#     detection (50% similarity) will NOT pair the deletion with it —
#     main's side reads as "delete + add unrelated stub", not a rename.
#
#   - every other label (.crashed / .abandoned-wip / .partial /
#     .dispatch-failed): NO branch is ever re-merged for these, so there is
#     no deletion to collide with. We keep the content-preserving `git mv`
#     rename so a human recovers by simply renaming the marker back to
#     `<slug>.md` to re-queue (the recovery runbooks rely on this).
#
# Either way the marker keeps the SAME `<slug>.<marker>.<ts>.md` name in
# queued/, so the forensic-marker glob filters (list_eligible_tasks, the
# dependency checks) keep skipping the slug unchanged.
#
# And either way the move breaks inbound markdown links to the brief's
# original path, so after staging, both paths run _stage_link_repairs
# (see its comment) and stage the rewritten files into the same marker
# commit. A repair failure rolls everything back and halts, like any
# other staging failure. Human re-queue (renaming a marker back to
# `<slug>.md`) re-breaks the links, but that is an attended operation
# and the gate fails loudly at commit time — accepted.
#
# This function MUST be atomic across iterations: either HEAD advances
# past the original task name, or main's index + working tree are left
# exactly as we found them. The previous rename implementation did
# `git mv` first and `git commit` second with a partial pathspec — when
# the commit failed (which it does unconditionally during a merge, since
# git forbids `git commit -- <pathspec>` mid-merge), the rename was left
# half-applied: gone from both index and disk under its original name,
# present under the marker name but uncommitted. The next iteration's
# mark_queue_file then silently no-op'd, HEAD never advanced, and the
# loop spun on the same task forever. The 2026-05-22 infinite-loop
# incident traces directly to that asymmetry.
#
# Both paths are fail-stop: hard pre-checks (no merge in progress, no
# unrelated staged content), then the rm+stub or git-mv staging followed
# by a pathspec-less `git commit` (commits exactly the staged change —
# safe because the pre-check verified the index was otherwise clean). Any
# failure rolls back the staged change and halts the runner via
# _halt_on_mark_failure. Halting beats continuing: the only way
# mark_queue_file can fail is a broken main, and processing more tasks
# against a broken main only widens the damage.
#
# Self-locks via acquire_main_lock so it is safe to call from a sibling
# runner's iteration AND from inside the already-locked merge block (the
# re-entrant counter absorbs the nested acquire).
#
# $4 is optional: the forensic record this failure wrote, passed through
# to _write_marker_stub so the committed stub names the file that
# actually exists. Empty (or omitted) means no record was written, which
# the stub then says outright rather than pointing at nothing. Only the
# merge-failed path emits a stub, so $4 is meaningless for other labels.
mark_queue_file() {
  local task_file="$1"
  local marker="$2"
  local ts="$3"
  local record_path="${4:-}"
  local marked="${task_file%.md}.${marker}.${ts}.md"
  local rel_src rel_dst basename
  rel_src="${task_file#$ROOT/}"
  rel_dst="${marked#$ROOT/}"
  basename="$(basename "$task_file" .md)"

  acquire_main_lock

  # Pre-check 1: refuse during a merge. `git commit` mid-merge with a
  # pathspec is explicitly forbidden by git; a pathspec-less commit
  # would lock conflict-resolved content into HEAD. The only safe
  # response is to halt and let the operator untangle main.
  if git -C "$ROOT" rev-parse --verify --quiet MERGE_HEAD >/dev/null 2>&1; then
    _halt_on_mark_failure "$basename" \
      "main is mid-merge (MERGE_HEAD present); cannot commit a marker rename mid-merge"
  fi

  # Pre-check 2: refuse if main's index has staged content we didn't
  # put there. The pathspec-less commit below would otherwise pick it
  # up. The runner expects a clean main between iterations; if it
  # isn't, something else has gone wrong already.
  if ! git -C "$ROOT" diff --cached --quiet 2>/dev/null; then
    _halt_on_mark_failure "$basename" \
      "main has unrelated staged content; a pathspec-less marker commit would capture it"
  fi

  if git -C "$ROOT" ls-files --error-unmatch "$rel_src" >/dev/null 2>&1; then
    if [[ "$marker" == "merge-failed" ]]; then
      # Re-merged on retry — record collision-proof: `git rm` the original
      # (matches the worker branch's own deletion, so a re-merge is a clean
      # both-sides-delete) and write a fresh, deliberately-dissimilar stub
      # at the marker path so git won't rename-pair the deletion with it.
      # Stage both, then commit.
      if ! git -C "$ROOT" rm --quiet "$rel_src" >/dev/null 2>&1; then
        _halt_on_mark_failure "$basename" "git rm failed staging the merge-failed marker deletion"
      fi
      _write_marker_stub "$marked" "$basename" "$marker" "$ts" "$record_path" "${LOG_FILE:-}"
      if ! git -C "$ROOT" add -- "$rel_dst" >/dev/null 2>&1; then
        git -C "$ROOT" restore --source=HEAD --staged --worktree -- "$rel_src" >/dev/null 2>&1 || true
        rm -f "$marked"
        _halt_on_mark_failure "$basename" "git add failed staging the merge-failed stub; rolled back"
      fi
      if ! _stage_link_repairs "$rel_src" "$rel_dst"; then
        _restore_link_repairs
        git -C "$ROOT" restore --source=HEAD --staged --worktree -- "$rel_src" "$rel_dst" >/dev/null 2>&1 || true
        rm -f "$marked"
        _halt_on_mark_failure "$basename" "inbound-link repair failed staging the merge-failed marker; rolled back"
      fi
      # Pathspec-less commit: the index was clean before our staging, so
      # this commits exactly the deletion + stub addition + link repairs —
      # nothing else. On failure, roll all of it back via `git restore`
      # (and delete the stub) so a future attempt starts from a coherent
      # state instead of the half-applied change that caused the
      # 2026-05-22 loop.
      if ! git -C "$ROOT" commit -m "task-queue: mark $basename as $marker" >/dev/null 2>&1; then
        _restore_link_repairs
        git -C "$ROOT" restore --source=HEAD --staged --worktree -- "$rel_src" "$rel_dst" >/dev/null 2>&1 || true
        rm -f "$marked"
        _halt_on_mark_failure "$basename" "git commit failed after staging the merge-failed marker; rolled back"
      fi
      echo "[task-queue] committed merge-aware marker: $(basename "$marked")"
    else
      # Not re-merged — keep the content-preserving rename so a human can
      # rename the marker back to <slug>.md to re-queue. On commit failure,
      # roll the `git mv` back so a future attempt starts coherent instead
      # of the half-applied rename that caused the 2026-05-22 loop.
      if ! git -C "$ROOT" mv "$rel_src" "$rel_dst" >/dev/null 2>&1; then
        _halt_on_mark_failure "$basename" "git mv failed staging the marker rename"
      fi
      if ! _stage_link_repairs "$rel_src" "$rel_dst"; then
        _restore_link_repairs
        git -C "$ROOT" restore --source=HEAD --staged --worktree -- "$rel_src" "$rel_dst" >/dev/null 2>&1 || true
        _halt_on_mark_failure "$basename" "inbound-link repair failed staging the marker rename; rolled back"
      fi
      if ! git -C "$ROOT" commit -m "task-queue: mark $basename as $marker" >/dev/null 2>&1; then
        _restore_link_repairs
        git -C "$ROOT" restore --source=HEAD --staged --worktree -- "$rel_src" "$rel_dst" >/dev/null 2>&1 || true
        _halt_on_mark_failure "$basename" "git commit failed after staging the rename; rolled back"
      fi
      echo "[task-queue] committed marker rename: $(basename "$marked")"
    fi
  elif [[ -f "$task_file" ]]; then
    # Defensive fallback: file is on disk but not tracked (shouldn't
    # happen under HEAD-watching pickup, but keep the path open for
    # manual queue insertion that bypassed git). merge-failed drops a
    # dissimilar stub (collision-proof); every other label plain-renames
    # so it can be renamed back. Next iteration's HEAD scan skips it either way.
    if [[ "$marker" == "merge-failed" ]]; then
      rm -f "$task_file"
      _write_marker_stub "$marked" "$basename" "$marker" "$ts" "$record_path" "${LOG_FILE:-}"
    else
      mv "$task_file" "$marked"
    fi
    echo "[task-queue] (untracked) marked queue file: $(basename "$marked")"
  else
    # Already absent from both index and disk under the original
    # name. Don't halt — list_eligible_tasks reads HEAD, so this name
    # is already off the eligible list either way. (This is the state
    # a previous half-applied marker commit would have left behind;
    # logging it makes residual incidents visible.)
    echo "[task-queue] note: $basename absent from index AND disk; nothing to mark"
  fi
  release_main_lock
}

# Halt the runner with a recoverable STUCK record. Called by
# mark_queue_file when it cannot advance HEAD past the current task —
# continuing in that state would re-claim the same task on the next
# iteration and spin the loop. Every prior version of this failure
# path tried to continue and made things worse; this one is deliberately
# non-recoverable in-process. The STUCK record gives the operator the
# exact paths and commands to repair main and resume.
_halt_on_mark_failure() {
  local basename="$1"
  local reason="$2"
  local stuck_file="$STATE_DIR/STUCK-$(date +%Y%m%d-%H%M%S)-mark-failed-${basename}.md"
  cat >"$stuck_file" <<EOF
# Stuck — runner halted on mark_queue_file failure

The task-queue runner could not advance HEAD past
\`${QUEUE_REL}/${basename}.md\`. Continuing would re-pick
the same task on the next iteration and spin the loop forever, so the
runner halted.

**Reason:** $reason

## Recovery

1. Inspect main's state — look for \`MERGE_HEAD\`, unmerged paths,
   unexpected staged content, or a half-staged marker (a staged rename,
   or the task doc removed + a stub added, but uncommitted) from an
   earlier failed run:
   \`\`\`
   git -C $ROOT status
   git -C $ROOT diff --cached --stat
   git -C $ROOT log --oneline -5
   \`\`\`
2. Resolve whatever you find. Typical recoveries:
   - \`git merge --abort\` if mid-merge.
   - \`git restore --source=HEAD --staged --worktree -- <paths>\` to
     undo a half-staged marker that didn't commit.
   - \`git reset --hard HEAD\` if the index is staged with content you
     don't recognise (verify first — this is destructive).
3. Decide what to do with the original task file at
   \`${QUEUE_REL}/${basename}.md\`. If the worker actually
   completed and committed on its branch, merge the branch manually;
   otherwise re-queue the file or move it to \`blocked/\`.
4. Clean up any leftover worktree at
   \`.task-queue/worktrees/${basename}/\` and its branch
   \`task-queue/${basename}\` once recovery is done.
EOF
  echo "[task-queue] FATAL: $reason"
  echo "[task-queue] details: $stuck_file"
  release_main_lock 2>/dev/null || true
  exit 1
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Look up the stash entry created by THIS runner via its unique message,
# echo the ref (e.g. "stash@{2}") on stdout, return 0 if found. Returns
# non-zero with no output if no matching stash is in the list. Multiple
# concurrent runners can push stashes; a naive `git stash pop` would grab
# whichever happens to be at stash@{0}, which may not be ours. `grep -F`
# matches the message as a fixed string; awk pulls the leading ref. The
# stash list format is "stash@{N}: <type>: <message>" — taking field 1
# splits cleanly on ':' even though the message itself contains colons.
find_our_stash_ref() {
  local stash_msg="$1"
  local ref
  ref=$(git -C "$ROOT" stash list | grep -F "$stash_msg" | head -1 | awk -F: '{print $1}')
  if [[ -z "$ref" ]]; then
    return 1
  fi
  printf '%s\n' "$ref"
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Remove the worktree and its branch. Called on the success path and on the
# submodule-populate failure path (a half-populated worktree is not a place
# to spawn a worker).
# Uses `git worktree remove --force` because the worker may have left
# untracked artifacts (build outputs, etc.) that we don't want to babysit.
cleanup_worktree() {
  local worktree="$1"
  local branch="$2"
  if [[ -d "$worktree" ]]; then
    git -C "$ROOT" worktree remove --force "$worktree" 2>/dev/null \
      || rm -rf "$worktree"
  fi
  if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$ROOT" branch -D "$branch" >/dev/null 2>&1 || true
  fi
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# True when the runner must NOT mutate this worktree: it holds uncommitted
# tracked changes, unmerged index entries, or an in-progress git operation.
# Sets WORKTREE_BUSY_REASON to a one-line explanation when it returns 0.
#
# This is the teardown-side guard from the 2026-07-31 incident. The runner
# stopped a worker that was mid-`git commit` (a backgrounded pre-commit run)
# and then staged a `git rm` of the brief into its worktree while that commit
# was still going. Neither runner asked whether the tree was mid-write first.
#
# Untracked files are deliberately NOT a reason to refuse. The runner itself
# symlinks untracked paths into every worktree (stage_shared_paths), and test
# and build runs leave more, so a bare `git status --porcelain` — which
# reports untracked by default — would refuse on every healthy worktree and
# turn a race guard into a permanent outage. The question that actually needs
# answering is "is anything mid-write here?": tracked-dirty, unmerged, or an
# operation in progress. Note the first of those alone already catches a
# running `git commit` — staged content makes `git diff HEAD` non-empty until
# the commit lands — with the *_HEAD/lock markers as defense in depth.
#
# A worktree we cannot interrogate at all (missing, or `git` erroring) reads
# as busy: refusing to mutate something we can't inspect is the safe default.
WORKTREE_BUSY_REASON=""
worktree_busy() {
  local wt="$1" gitdir marker
  WORKTREE_BUSY_REASON=""
  if [[ ! -d "$wt" ]]; then
    WORKTREE_BUSY_REASON="worktree directory is missing"
    return 0
  fi
  if ! git -C "$wt" diff --quiet HEAD 2>/dev/null; then
    WORKTREE_BUSY_REASON="uncommitted changes to tracked files"
    return 0
  fi
  if [[ -n "$(git -C "$wt" ls-files --unmerged 2>/dev/null)" ]]; then
    WORKTREE_BUSY_REASON="unmerged index entries"
    return 0
  fi
  if ! gitdir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null); then
    WORKTREE_BUSY_REASON="not a readable git worktree"
    return 0
  fi
  for marker in index.lock MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD \
                rebase-merge rebase-apply sequencer; do
    if [[ -e "$gitdir/$marker" ]]; then
      WORKTREE_BUSY_REASON="git operation in progress ($marker present)"
      return 0
    fi
  done
  return 1
}

# Validate a worker's success signal against tracked state before the
# runner merges. The worker reported done (clean exit, new commits, no
# dirty tracked files) — but self-reporting is trusted nowhere else in
# this pipeline, so the success path gets the same scrutiny. Checks:
#   1. The brief is absent from the worktree. The worker's closure commit
#      (or, failing that, the runner's fallback queue-file `git rm`) ran
#      just before this; the brief still on disk means both missed — e.g.
#      the fallback commit failed a whole-tree doc-links gate on inbound
#      links — and merging would return the task to queued/ unfinished.
#   2. At least one commit exists beyond START_SHA on the task branch
#      (structurally guaranteed by the caller's ADVANCED gate; re-checked
#      so the function stands alone).
#   3. No leftover STUCK.md in the worktree — a worker that wrote one and
#      then reported success is contradicting itself.
#   4. `pytest --collect-only` succeeds — a cheap import-integrity probe
#      (a worker that left the tree unimportable cannot have run the full
#      suite it implies passed), NOT a substitute for the full run the
#      worker owns. Skipped with a log line when the worktree has no
#      .venv to run it with.
# On failure: sets VALIDATE_FAILURE to a one-line reason and returns 1.
# The caller marks the brief `.partial.<ts>.md` and keeps the worktree —
# same forensic treatment as .abandoned-wip, distinct marker so the two
# are tellable apart in `git log`.
# NOT mirrored in audit-queue/run.sh — audit workers have no brief to
# validate against.
VALIDATE_FAILURE=""
validate_worker_state() {
  local worktree="$1" task_rel="$2" start_sha="$3"
  VALIDATE_FAILURE=""
  if [[ -f "$worktree/$task_rel" ]]; then
    VALIDATE_FAILURE="brief still present in the worktree (queue-file git rm failed?)"
    return 1
  fi
  if [[ -z "$(git -C "$worktree" rev-list -1 "${start_sha}..HEAD" 2>/dev/null)" ]]; then
    VALIDATE_FAILURE="no commits beyond START_SHA on the task branch"
    return 1
  fi
  if [[ -f "$worktree/STUCK.md" ]]; then
    VALIDATE_FAILURE="leftover STUCK.md in the worktree"
    return 1
  fi
  if [[ -x "$worktree/.venv/bin/python" ]]; then
    if ! (cd "$worktree" && .venv/bin/python -m pytest --collect-only -q) \
         >>"${LOG_FILE:-/dev/null}" 2>&1; then
      VALIDATE_FAILURE="pytest --collect-only failed (unimportable tree or broken test collection)"
      return 1
    fi
  else
    echo "[task-queue] validate: no .venv in worktree — skipping the pytest collect probe"
  fi
  return 0
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Convert a timeout string ("60m", "2h", "30s", or a bare number) to
# seconds. Empty input echoes empty (no timeout). Anything we don't
# recognize is echoed unchanged and assumed to already be seconds.
parse_timeout_to_seconds() {
  local t="$1"
  if [[ -z "$t" ]]; then echo ""; return; fi
  local unit="${t: -1}"
  local n="${t%?}"
  case "$unit" in
    s|S) echo "$n" ;;
    m|M) echo $(( n * 60 )) ;;
    h|H) echo $(( n * 3600 )) ;;
    *)   echo "$t" ;;
  esac
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Wait for a backgrounded `claude --bg` session to terminate.
#
# `claude --bg` dispatches through the Agent View daemon and returns
# immediately, so the runner can't simply read claude's exit code to
# decide what to do next. Instead we poll the per-session state file at
# ~/.claude/jobs/<short-id>/state.json, which the daemon updates as the
# session moves through its lifecycle. Terminal states are "done" (clean
# exit), "failed" (crash), and "stopped" (manual `claude stop`). Note a
# SIGTERM to a --bg session is NOT terminal: the daemon records it as
# "crashed" (exit 143) and auto-respawns into a non-terminal "running"/idle
# session (firstTerminalAt: null), so self-terminate.sh's SIGTERM walk does
# not land "done" here. Neither runner relies on that path: the task-queue
# worker runs under interactive `claude` (where the SIGTERM walk is correct),
# and the audit-queue worker is stopped by the runner (takeover at
# state=blocked, with check_stall_signature recovering any respawned/idle
# session).
#
# Args:
#   $1 — short session id (8-char hex prefix printed by `claude --bg`)
#   $2 — timeout in seconds; empty disables the timeout
#
# Writes operator-facing progress to stdout — takeover notices, and the
# background-work episode records (see bg_episode_track). No caller reads
# that stdout; the RETURN CODE is the signal:
#   0   — state==done
#   1   — state==failed or state==stopped, or pre-flight failed
#   124 — timeout elapsed; runner-side `claude stop` was issued
#   143 — runner-initiated stall stop (STALL_FORCED=1); treat as success

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync (asserted
# byte-identical by task-queue/test-run.sh).
# Echo the number of background tasks the daemon currently has in flight for
# this session. Returns 1 with NO output when that count is unavailable.
#
# `inFlight` is an UNDOCUMENTED Agent View daemon internal, read straight out
# of ~/.claude/jobs/<id>/state.json. Probed 2026-07-31 on Claude Code 2.1.220:
# it tracks backgrounded Bash directly — `{"tasks": 1, "queued": 0, "kinds":
# ["local_bash"]}` while the command runs, dropping to `tasks: 0` the moment
# it completes — and it is dropped from state.json entirely once a session is
# `claude stop`ped. Nothing contractual guarantees any of that, so every
# caller must treat "unavailable" as a first-class answer rather than as 0.
# Pure by design — reporting the unavailable case is note_inflight_unavailable's
# job, for the subshell reasons documented there.
worker_bg_task_count() {
  local short_id="$1"
  local state_file="$HOME/.claude/jobs/$short_id/state.json"
  local n=""
  [[ -f "$state_file" ]] && n=$(jq -r '.inFlight.tasks // empty' "$state_file" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$n"
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync (asserted
# byte-identical by task-queue/test-run.sh).
# Report — at most once per runner — that the daemon no longer exposes a
# numeric inFlight.tasks, so the gating below has degraded to its fail-safe.
#
# Kept out of worker_bg_task_count because two separate hazards would each
# silently defeat an `echo` placed there:
#   - That function's STDOUT is its return value, and every caller reads it
#     through `$( )`. A note printed to stdout is captured into the caller's
#     variable and never reaches the log. Hence `>&2` here.
#   - The once-only flag has to be set in the RUNNER's shell. An assignment
#     made inside a `$( )` subshell dies with the subshell, so the "once"
#     note would reappear on every 5s poll — noise that reads as a storm of
#     new failures rather than one degraded field.
# Callers must therefore invoke this DIRECTLY, never through `$( )`.
note_inflight_unavailable() {
  (( INFLIGHT_UNAVAILABLE_LOGGED )) && return 0
  INFLIGHT_UNAVAILABLE_LOGGED=1
  echo "[$LOG_TAG] note: daemon state.json exposes no numeric inFlight.tasks — background-work gating is degraded (stall takeover disabled, blocked-state takeover unheld). If this persists, Claude Code changed the field." >&2
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync (asserted
# byte-identical by task-queue/test-run.sh).
# True only when the daemon POSITIVELY reports background work in flight for
# this session. An unavailable count reads as "not armed" here on purpose:
# this predicate gates a HOLD, and holding on absent data is how a runner
# hangs forever. check_stall_signature gates a KILL from the same counter and
# so resolves the unavailable case the other way. The asymmetry is deliberate
# — each caller fails toward leaving the worker alone AND finishing the task.
worker_bg_work_armed() {
  local n
  n=$(worker_bg_task_count "$1") || { note_inflight_unavailable; return 1; }
  (( n > 0 ))
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync (asserted
# byte-identical by task-queue/test-run.sh).
# Echo how many seconds the worker's session has been QUIET — no new activity
# in its JSONL. Returns 1 with NO output when quiet is not measurable.
#
# Quiet is anchored on the LATER of (a) the most recent tool_result and (b)
# the most recent assistant message. The second clause is what catches the
# "I'm done" text-after-result pattern: the worker said text but produced no
# follow-up tool_use, and the daemon hasn't transitioned state to "done"
# either. Giving the model up to STALL_GRACE_S past its most recent activity
# to produce real work is the false-positive defense.
#
# Three cases return "unmeasurable" rather than a number, and each is a
# deliberate not-a-stall for the one caller that compares against a grace
# window: no tool_use yet (too early in the dispatch to judge), the latest
# tool_use has no tool_result yet (a tool is still executing — long Bash,
# subagent run, or an AskUserQuestion waiting on the user's phone, none of
# which is quiet at all), and an unparseable timestamp.
#
# Split out of check_stall_signature so probe-completion-detection.sh can
# assert that a live session genuinely crossed STALL_GRACE_S using the
# runner's OWN measurement. A re-derived copy in the probe could drift from
# this one, and a probe that measures the window differently from the code it
# is validating proves less than it appears to.
#
# Args: $1 — path to the worker's JSONL (may be empty).
worker_quiet_seconds() {
  local jsonl="$1"
  [[ -z "$jsonl" || ! -f "$jsonl" ]] && return 1
  # Most recent assistant tool_use's id.
  local last_tool_id
  last_tool_id=$(grep -E '"type":"assistant"' "$jsonl" 2>/dev/null \
                  | jq -r 'select(.message.content) | (.message.content[]? | select(.type == "tool_use") | .id)' 2>/dev/null \
                  | tail -1)
  [[ -z "$last_tool_id" ]] && return 1
  local result_ts
  result_ts=$(grep -F "\"tool_use_id\":\"$last_tool_id\"" "$jsonl" 2>/dev/null \
              | head -1 \
              | jq -r '.timestamp // empty' 2>/dev/null)
  [[ -z "$result_ts" ]] && return 1
  local last_asst_ts anchor
  last_asst_ts=$(grep -E '"type":"assistant"' "$jsonl" 2>/dev/null \
                  | tail -1 \
                  | jq -r '.timestamp // empty' 2>/dev/null)
  anchor="$result_ts"
  if [[ -n "$last_asst_ts" && "$last_asst_ts" > "$anchor" ]]; then
    anchor="$last_asst_ts"
  fi
  local ref_epoch now_epoch
  ref_epoch=$(date -d "$anchor" +%s 2>/dev/null) || return 1
  now_epoch=$(date +%s)
  printf '%s' "$(( now_epoch - ref_epoch ))"
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync (asserted
# byte-identical by task-queue/test-run.sh).
# Open, or extend, the record of one EPISODE of in-flight background work:
# a contiguous stretch of polls during which the daemon reported
# inFlight.tasks > 0 for this session.
#
# Why this exists. The background-work gate added after the 2026-07-31
# incident is silent by construction — a suppressed false positive produces
# no output at all, so a runner log carries no evidence the guard ever
# engaged, or ever could have. The first end-to-end run after the fix
# (2026-07-31, merged at 8ba9aa2c0) passed cleanly while never once reaching
# the guarded state: 255 of 258 sampled polls sat at tempo=active, where
# check_stall_signature's FIRST gate (`tempo != idle`) already returns
# not-a-stall, so the new inFlight check was never reached. Nothing in the
# repo would have caught that; only a bespoke sampler running alongside did.
# These two lines are what make the same miss visible in any runner log.
#
# The counts are the point, and BG_EPISODE_IDLE_POLLS especially. A poll at
# tempo=active is protected by the pre-existing tempo gate, so an episode
# spent entirely at tempo=active demonstrates nothing about the inFlight
# gate. A poll at tempo=idle with work armed is the state where the inFlight
# gate is the ONLY thing standing between a healthy worker and a takeover.
# Hence the deliberately FACTUAL wording of both lines — "background work in
# flight", never "guard engaged": the runner cannot tell from an episode
# alone which gate did the work, and the idle count is what settles it.
#
# The episode boundary lives here rather than in check_stall_signature
# because that function is stateless across calls and is not even reached on
# every path (the state=blocked branch returns before it). State is carried
# in globals rather than caller locals so the bookkeeping can be driven
# directly by test-run.sh with a scripted sequence of (armed, tempo) pairs —
# a polling loop is otherwise untestable without a daemon and an LLM.
#
# Args: $1 — short session id; $2 — 1 if armed, 0 if not; $3 — daemon tempo;
#       $4 — current epoch seconds; $5 — the reported inFlight.tasks count.
bg_episode_track() {
  local short_id="$1" armed="$2" tempo="$3" now="$4" count="$5"
  if (( armed == 0 )); then
    bg_episode_close "$short_id" "$now" "the daemon's count drained to 0"
    return 0
  fi
  if (( BG_EPISODE_SINCE == 0 )); then
    BG_EPISODE_SINCE=$now
    BG_EPISODE_POLLS=0
    BG_EPISODE_IDLE_POLLS=0
    echo "[$LOG_TAG] $short_id: background work in flight (inFlight.tasks=$count) — takeover held until it drains"
  fi
  BG_EPISODE_POLLS=$(( BG_EPISODE_POLLS + 1 ))
  [[ "$tempo" == "idle" ]] && BG_EPISODE_IDLE_POLLS=$(( BG_EPISODE_IDLE_POLLS + 1 ))
  return 0
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync (asserted
# byte-identical by task-queue/test-run.sh).
# Drop any episode state SILENTLY. Called once at the top of each
# wait_for_bg_session so a fresh wait never inherits a previous worker's
# half-open episode and closes it with that worker's elapsed time. Distinct
# from bg_episode_close, which is the one that speaks: an inherited episode
# has nothing true to report, so reporting nothing is the correct record.
bg_episode_reset() {
  BG_EPISODE_SINCE=0
  BG_EPISODE_POLLS=0
  BG_EPISODE_IDLE_POLLS=0
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync (asserted
# byte-identical by task-queue/test-run.sh).
# Close an open background-work episode with one summary line, and reset.
# A no-op when no episode is open, which is what keeps a run that never
# entered the state silent — and keeps the pair of lines from degenerating
# into per-poll noise.
#
# The `$3` qualifier distinguishes the healthy close (the count drained) from
# the diagnostic one (the runner stopped waiting while the count was still
# above 0). The latter is how a LEAKED counter — observed on Claude Code
# 2.1.217, a session reaching state=done still reporting tasks:28 — becomes
# visible as an episode that never drained, rather than as silence.
#
# Args: $1 — short session id; $2 — current epoch seconds; $3 — how it ended.
bg_episode_close() {
  local short_id="$1" now="$2" how="$3"
  (( BG_EPISODE_SINCE == 0 )) && return 0
  echo "[$LOG_TAG] $short_id: background-work episode ended after $(( now - BG_EPISODE_SINCE ))s — $BG_EPISODE_POLLS polls, $BG_EPISODE_IDLE_POLLS at tempo=idle (where the inFlight gate is the only thing holding takeover off); $how"
  BG_EPISODE_SINCE=0
  BG_EPISODE_POLLS=0
  BG_EPISODE_IDLE_POLLS=0
  return 0
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Check whether the worker's session has stalled — alive but no longer
# making progress — so the runner can take over. This is the fallback for
# a worker the daemon respawned into a non-terminal idle session; ordinary
# completion arrives as state=done or state=blocked in wait_for_bg_session.
#
# A stall is confirmed when ALL of the following hold:
#   1. tempo == idle and state is non-terminal — never interrupt a worker
#      that is mid-tool, mid-subagent, or mid-thinking.
#   2. The daemon reports NO background work in flight (worker_bg_task_count
#      == 0) — OR it has been reporting some for longer than STALL_BG_MAX_S
#      of unbroken worker quiet, the bound that keeps a count which never
#      drains from suppressing recovery forever. This is the guard added
#      after the 2026-07-31 incident; see the block comment at that check
#      for why both halves are load-bearing.
#   3. The session's most recent tool_use already has its tool_result — a
#      tool still executing (long Bash, subagent, pending AskUserQuestion)
#      is not a stall.
#   4. Nothing has happened for ≥ STALL_GRACE_S seconds, anchored on the
#      LATER of that tool_result and the latest assistant message.
#
# The docstring here once described this as reading the daemon's
# "Continue from where you left off." respawn nudge and finding it
# unanswered. It never did: it measures quiet time only, and the nudge's
# text appears nowhere below. That gap between the stated and actual
# signal is why the backgrounded-command false positive went unnoticed —
# the described signal genuinely would have been suppressed during a
# background wait, while the implemented one fires squarely inside it.
#
# Args: $1 — short session id; $2 — path to the worker's JSONL (may be empty)
# Returns 0 if stall is confirmed, 1 otherwise.
check_stall_signature() {
  local short_id="$1"
  local jsonl="$2"
  [[ -z "$jsonl" || ! -f "$jsonl" ]] && return 1
  local state_file="$HOME/.claude/jobs/$short_id/state.json"
  [[ ! -f "$state_file" ]] && return 1
  # The daemon's `tempo` flag distinguishes "actively processing" from
  # "idle between turns". Stall detection only applies in the idle case
  # — never interrupt a worker that's mid-tool / mid-subagent / mid-
  # thinking. State.json's terminal states are handled by the outer
  # wait loop; check_stall_signature is for the "alive but stuck" case.
  local tempo state
  tempo=$(jq -r '.tempo // empty' "$state_file" 2>/dev/null)
  state=$(jq -r '.state // empty' "$state_file" 2>/dev/null)
  [[ "$tempo" != "idle" ]] && return 1
  case "$state" in done|stopped|failed|blocked) return 1 ;; esac

  # Background-work gate — the false positive this whole function used to
  # produce. A worker that backgrounded a long command (the worker prompts
  # REQUIRE it: the commit gate outruns tool timeouts) gets an instant
  # "running in background" tool_result, ends its turn to await the
  # completion notification, and sits at state=working tempo=idle — quiet,
  # answered, and past grace. Every timing signal below reads that as a
  # stall. The daemon's own inFlight counter is the discriminator: > 0 means
  # work is armed and the quiet is exactly what a healthy worker looks like.
  #
  # An UNAVAILABLE count is treated as "not a stall" deliberately. inFlight
  # is an undocumented daemon internal; if a future Claude Code release
  # drops or renames it, this guard must degrade to "never take over" — no
  # stall detection at all, with completion still handled by the state=done
  # and state=blocked paths in wait_for_bg_session — rather than silently
  # reverting to killing healthy workers mid-commit (the 2026-07-31
  # incident). worker_bg_task_count logs the degradation once.
  #
  # The suppression is BOUNDED, because a positive count is not always a
  # transient condition. A persistent Monitor stays armed for the worker's
  # whole session, and the daemon leaves a hung session at state=working —
  # where this function is the only recovery path there is. Unbounded, the
  # runner would wait on such a worker forever. Past STALL_BG_MAX_S of
  # unbroken quiet the count stops earning the benefit of the doubt and the
  # stall is declared, with its own stderr line so an operator can tell a
  # stuck counter from a stuck model. Quiet is measured off the worker's
  # JSONL, so any real activity resets the bound; an UNMEASURABLE quiet
  # stays not-a-stall, matching the ordinary path below.
  local bg_tasks
  if ! bg_tasks=$(worker_bg_task_count "$short_id"); then
    note_inflight_unavailable
    return 1
  fi
  if (( bg_tasks > 0 )); then
    local bg_quiet
    bg_quiet=$(worker_quiet_seconds "$jsonl") || return 1
    (( bg_quiet < ${STALL_BG_MAX_S:-1800} )) && return 1
    echo "[$LOG_TAG] $short_id: quiet ${bg_quiet}s with inFlight.tasks=$bg_tasks still armed — past STALL_BG_MAX_S (${STALL_BG_MAX_S:-1800}s); treating the count as persistent and declaring a stall" >&2
    return 0
  fi

  # How long the session has been quiet, measured off its JSONL. An
  # unmeasurable answer — no tool_use yet, a tool_result still outstanding,
  # an unparseable timestamp — is not a stall; see worker_quiet_seconds for
  # why each of those cases is a deliberate not-a-stall rather than a zero.
  local elapsed
  elapsed=$(worker_quiet_seconds "$jsonl") || return 1
  (( elapsed >= ${STALL_GRACE_S:-30} ))
}

# Returns 0 if the worker's JSONL ends with an UNANSWERED AskUserQuestion
# tool_use — i.e. a phone dialog is genuinely pending and the runner must
# keep waiting rather than take over. Returns 1 otherwise (question already
# answered, last tool wasn't a question, or JSONL unavailable).
#
# This is a defense-in-depth backstop to the daemon's `tempo=active` signal
# (see the blocked-state handling in wait_for_bg_session). If tempo briefly
# flickers to "blocked" at the instant a question is posted, this JSONL check
# still holds the runner back from merging mid-question.
#
# Args: $1 — path to the worker's JSONL (may be empty).
worker_awaiting_user() {
  local jsonl="$1"
  [[ -z "$jsonl" || ! -f "$jsonl" ]] && return 1
  # Most recent assistant tool_use: capture its name + id together.
  local last name id
  last=$(grep -E '"type":"assistant"' "$jsonl" 2>/dev/null \
          | jq -rc 'select(.message.content) | (.message.content[]? | select(.type == "tool_use") | {id, name})' 2>/dev/null \
          | tail -1)
  [[ -z "$last" ]] && return 1
  name=$(printf '%s' "$last" | jq -r '.name // empty' 2>/dev/null)
  id=$(printf '%s' "$last" | jq -r '.id // empty' 2>/dev/null)
  [[ "$name" != "AskUserQuestion" ]] && return 1
  # A tool_result carrying this id means the user already answered.
  grep -F "\"tool_use_id\":\"$id\"" "$jsonl" >/dev/null 2>&1 && return 1
  return 0  # AskUserQuestion posted, no result yet → pending
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Returns 0 (keep waiting) when the worker is in a free-text clarification
# dialog and the human is plausibly still typing; 1 otherwise.
#
# When the user DECLINES an AskUserQuestion to chat instead of picking an
# option, Claude Code RESOLVES the tool_use with an is_error tool_result whose
# text is "The user doesn't want to proceed … The user wants to clarify …".
# The worker then (correctly) drops to a plain-text question — "what would you
# like to clarify?" — and ends its turn. That parks the session at
# state=blocked tempo=blocked, structurally identical to a finished task:
# worker_awaiting_user misses it (the question now HAS a tool_result), so the
# eager tempo=blocked takeover would `claude stop` the worker before the human
# can type. This check holds the runner back instead.
#
# Unlike a pending AskUserQuestion (which the runner waits on indefinitely),
# a plain-text turn-end is indistinguishable from genuine completion, so we
# cannot wait forever — we anchor on the human's most recent activity (the
# decline itself, or any later typed reply) and keep the session alive only
# while that is within CLARIFY_GRACE_S. Each new human message resets the
# window, so an active conversation never gets cut off; a human who walked
# away is closed out once the window lapses. check_stall_signature can't serve
# as the backstop here — it returns early on state=blocked.
#
# Args: $1 — path to the worker's JSONL (may be empty).
worker_in_clarification_dialog() {
  local jsonl="$1"
  [[ -z "$jsonl" || ! -f "$jsonl" ]] && return 1
  # Most recent assistant AskUserQuestion tool_use id.
  local q_id
  q_id=$(grep -E '"type":"assistant"' "$jsonl" 2>/dev/null \
          | jq -rc 'select(.message.content) | (.message.content[]? | select(.type=="tool_use" and .name=="AskUserQuestion") | .id)' 2>/dev/null \
          | tail -1)
  [[ -z "$q_id" ]] && return 1
  # Its tool_result, if any. No result → pending question, handled by
  # worker_awaiting_user; not our case.
  local line
  line=$(grep -F "\"tool_use_id\":\"$q_id\"" "$jsonl" 2>/dev/null | head -1)
  [[ -z "$line" ]] && return 1
  # Must be a decline-to-clarify: is_error with the daemon's rejection text.
  # A normal answer is is_error:false and falls through to takeover.
  local is_error content
  is_error=$(printf '%s' "$line" | jq -r --arg id "$q_id" '(.message.content[]? | select(.type=="tool_result" and .tool_use_id==$id) | .is_error) // false' 2>/dev/null)
  [[ "$is_error" != "true" ]] && return 1
  content=$(printf '%s' "$line" | jq -r --arg id "$q_id" '(.message.content[]? | select(.type=="tool_result" and .tool_use_id==$id) | .content) // empty' 2>/dev/null)
  case "$content" in
    *"doesn't want to proceed"*|*"wants to clarify"*) : ;;
    *) return 1 ;;
  esac
  # Anchor on the human's latest activity — the most recent non-meta user
  # message (the decline, or a later typed reply). Daemon "Continue" nudges
  # are isMeta and excluded. Keep alive while within the grace window.
  local last_human_ts ref now elapsed
  last_human_ts=$(grep -E '"type":"user"' "$jsonl" 2>/dev/null \
                  | jq -r 'select((.isMeta // false) == false) | .timestamp // empty' 2>/dev/null \
                  | tail -1)
  [[ -z "$last_human_ts" ]] && return 1
  ref=$(date -d "$last_human_ts" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  elapsed=$(( now - ref ))
  (( elapsed < ${CLARIFY_GRACE_S:-600} ))
}

wait_for_bg_session() {
  local short_id="$1"
  local timeout_s="$2"
  local state_file="$HOME/.claude/jobs/$short_id/state.json"
  local start_wait now elapsed state tempo pre_attempt fast_stop_issued=0
  local jsonl=""
  # Background-work hold state for the state=blocked branch below.
  # bg_hold_since is the epoch the current hold began (0 = not holding);
  # bg_hold_capped keeps the "hold expired" warning to one line.
  local bg_hold_since=0 bg_hold_capped=0 hold_bg=0
  # Per-poll episode inputs; the episode itself is carried in the
  # BG_EPISODE_* globals so test-run.sh can drive the bookkeeping directly.
  local ep_count ep_armed
  STALL_FORCED=0
  bg_episode_reset
  start_wait=$(date +%s)
  # Pre-flight: state.json appears moments after dispatch; tolerate ~30s
  # before declaring the daemon broken.
  for pre_attempt in $(seq 1 30); do
    [[ -f "$state_file" ]] && break
    sleep 1
  done
  if [[ ! -f "$state_file" ]]; then
    return 1
  fi
  while true; do
    # Locate the worker's JSONL lazily — it appears shortly after dispatch
    # under a directory whose name encodes the worktree path. Re-search
    # each iteration if not yet found. Needed by both the blocked-state
    # discriminator below and check_stall_signature.
    if [[ -z "$jsonl" || ! -f "$jsonl" ]]; then
      jsonl=$(find "$HOME/.claude/projects" -maxdepth 2 -name "${short_id}*.jsonl" \
                ! -path '*/subagents/*' 2>/dev/null | head -1)
    fi
    state=$(jq -r '.state // empty' "$state_file" 2>/dev/null || true)
    tempo=$(jq -r '.tempo // empty' "$state_file" 2>/dev/null || true)
    now=$(date +%s)
    # Episode record. This runs on EVERY poll, before the state dispatch,
    # because the race the inFlight gate exists to stop lives at
    # state=working — the branch below returns without ever consulting the
    # counter. An unavailable count reads as not-armed here, matching
    # worker_bg_work_armed; the degradation itself is reported once by
    # note_inflight_unavailable from check_stall_signature's call.
    ep_count=$(worker_bg_task_count "$short_id") || ep_count=0
    (( ep_count > 0 )) && ep_armed=1 || ep_armed=0
    bg_episode_track "$short_id" "$ep_armed" "$tempo" "$now" "$ep_count"
    case "$state" in
      done|failed|stopped)
        bg_episode_close "$short_id" "$now" \
          "the runner stopped waiting (state=$state) with the count still above 0"
        [[ "$state" == "done" ]] && return 0
        return 1
        ;;
      blocked)
        # state=blocked covers BOTH "turn ended, nothing pending" and
        # "waiting on an AskUserQuestion", told apart by tempo. tempo=active
        # → interactive wait, keep polling for the phone answer. tempo=blocked
        # → completion, runner takes over. worker_awaiting_user is a JSONL
        # backstop in case tempo flickers at the instant a question posts; a
        # transient tempo only costs one extra poll, so no grace timer needed.
        # worker_in_clarification_dialog covers the third case: the user
        # DECLINED a question to chat in free text, so the worker is now
        # awaiting a typed reply at state=blocked tempo=blocked — keep alive
        # while the human is plausibly still typing (its own grace timer).
        # `tempo` was read alongside `state` at the top of this iteration.
        # Fourth case, defensive: the turn ended while the daemon still
        # reports backgrounded work armed. The 2026-07-31 probe puts a
        # background wait at state=working, not blocked, so this branch is
        # not the observed race — but it encodes the same "quiet means
        # finished" assumption, and taking over here would `claude stop` a
        # worker mid-commit. Hold, but only up to BG_HOLD_MAX_S: the
        # counter has been seen to leak (see BG_HOLD_MAX_S), and an
        # unbounded hold on a leaked count never merges the task at all.
        hold_bg=0
        if worker_bg_work_armed "$short_id"; then
          now=$(date +%s)
          if (( bg_hold_since == 0 )); then
            bg_hold_since=$now
            echo "[task-queue] worker's turn ended with background work still in flight — holding takeover"
          fi
          if (( now - bg_hold_since < BG_HOLD_MAX_S )); then
            hold_bg=1
          elif (( bg_hold_capped == 0 )); then
            bg_hold_capped=1
            echo "[task-queue] background-work hold exceeded ${BG_HOLD_MAX_S}s — treating the daemon's inFlight count as stuck and taking over"
          fi
        else
          bg_hold_since=0
        fi
        if [[ "$tempo" == "active" ]] || worker_awaiting_user "$jsonl" \
           || worker_in_clarification_dialog "$jsonl" || (( hold_bg )); then
          : # interactive wait or armed background work — keep polling
        else
          STALL_FORCED=1
          bg_episode_close "$short_id" "$(date +%s)" \
            "the runner took over at state=blocked with the count still above 0"
          echo "[task-queue] worker ended its turn (state=blocked tempo=${tempo:-?}) — runner taking over"
          claude stop "$short_id" >/dev/null 2>&1 || true
          # Brief settle to let the daemon write state=stopped before the
          # main loop inspects worktree state.
          sleep 2
          return 143
        fi
        ;;
    esac
    if check_stall_signature "$short_id" "$jsonl"; then
      STALL_FORCED=1
      bg_episode_close "$short_id" "$(date +%s)" \
        "the runner declared a stall with the count still above 0"
      echo "[task-queue] stall: worker ignored daemon's Continue prompt past grace — runner taking over"
      claude stop "$short_id" >/dev/null 2>&1 || true
      # Brief settle to let the daemon write state=stopped before the
      # main loop inspects worktree state.
      sleep 2
      return 143
    fi
    # A fast stop (second INT/TERM) abandons the in-flight worker:
    # `claude stop` it through the daemon instead of blocking on it.
    # The worker then moves to state "stopped" and this loop returns 1
    # on the next poll. Issued once — the flag check is idempotent.
    if (( FAST_STOP )) && (( fast_stop_issued == 0 )); then
      fast_stop_issued=1
      echo "[task-queue] fast stop — stopping worker $short_id"
      claude stop "$short_id" >/dev/null 2>&1 || true
    fi
    if [[ -n "$timeout_s" ]]; then
      now=$(date +%s)
      elapsed=$(( now - start_wait ))
      if (( elapsed >= timeout_s )); then
        bg_episode_close "$short_id" "$now" \
          "the per-task timeout fired with the count still above 0"
        claude stop "$short_id" >/dev/null 2>&1 || true
        return 124
      fi
    fi
    sleep 5
  done
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Probe whether a LIVE runner currently holds a given slug's claim lock.
# A runner flock()s $LOCK_DIR/<slug>.lock for the whole task; an advisory
# flock is released by the kernel the instant its holder dies, so a lock
# we can re-acquire has no live runner behind it. This is the liveness
# test the orphan reconcile relies on, and it is exact against live
# sibling/parallel runners — their lock genuinely cannot be re-acquired.
#
# Returns 0 if a live runner holds the lock, 1 if it is free (or absent).
# Probes on a throwaway fd 7 and releases immediately, so probing never
# leaves a lock held.
runner_alive_for_slug() {
  local slug="$1"
  local lock_file="$LOCK_DIR/$slug.lock"
  [[ -e "$lock_file" ]] || return 1
  if exec 7>"$lock_file" && flock -n 7; then
    flock -u 7
    exec 7>&-
    return 1
  fi
  exec 7>&-
  return 0
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Reconcile orphaned task-queue/* branches at launch. An orphan is a
# branch with commits ahead of main whose claim lock is free — i.e. a
# run that a crash / SIGKILL / container restart interrupted between
# "worker committed" and "runner merged" (see the 2026-05-22 kaizen
# entry). Supervision and graceful stop cover the clean shutdown cases;
# this covers the violent ones.
#
# mode=report (default at launch): list each orphan, then return. Never
# halts, never silently ignores, never auto-merges.
# mode=recover (`run.sh recover`): merge each orphan into main and remove
# its worktree, branch, and lock. Recovery is an explicit operator
# action precisely because an automatic silent merge on launch is the
# behaviour we are trying to avoid.
reconcile_orphans() {
  local mode="$1"
  local branch slug found=0
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    slug="${branch#task-queue/}"
    [[ -n "$(git -C "$ROOT" rev-list "main..$branch" 2>/dev/null)" ]] || continue
    runner_alive_for_slug "$slug" && continue
    found=1
    if [[ "$mode" == "recover" ]]; then
      recover_orphan "$branch" "$slug"
    else
      echo "[task-queue] ORPHAN: $branch is ahead of main with no live runner behind it"
    fi
  done < <(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads/task-queue/ 2>/dev/null)
  if (( found )) && [[ "$mode" != "recover" ]]; then
    echo "[task-queue] recover orphaned branches with:  bash $SELF recover"
  elif (( found == 0 )) && [[ "$mode" == "recover" ]]; then
    echo "[task-queue] no orphaned branches to recover"
  fi
  return 0
}

# Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
# Recover one orphaned branch: merge it into main with the same
# autostash -> merge --no-ff -> pop dance the success path uses (under
# the host-wide main lock) and, on a clean merge, remove its worktree,
# branch, and claim lock. A conflicting orphan is left intact for a
# human. Loud by design — recovery should be auditable in the log.
# (audit-queue's twin runs WITHOUT the main lock — audit-queue has no
# main lock yet, a known follow-up.)
recover_orphan() {
  local branch="$1" slug="$2"
  local worktree="$WORKTREE_DIR/$slug"
  local stashed="no" stash_msg="task-queue: autostash before recovering ${slug} [pid=$$]"
  echo "[task-queue] recovering orphan $branch"
  acquire_main_lock
  if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
    if git -C "$ROOT" stash push -m "$stash_msg" >/dev/null 2>&1; then
      stashed="yes"
    else
      echo "[task-queue] WARNING: stash push failed — skipping recovery of $branch"
      release_main_lock
      return 1
    fi
  fi
  git -C "$ROOT" update-index --refresh >/dev/null 2>&1 || true
  if git -C "$ROOT" merge --no-ff "$branch" \
       -m "task-queue: merge recovered orphan ${slug}" >/dev/null 2>&1; then
    echo "[task-queue] recovered: merged $branch into main"
    if [[ -d "$worktree" ]]; then
      git -C "$ROOT" worktree remove --force "$worktree" >/dev/null 2>&1 || rm -rf "$worktree"
    fi
    git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch" \
      && git -C "$ROOT" branch -D "$branch" >/dev/null 2>&1
    rm -f "$LOCK_DIR/$slug.lock"
  else
    # If `merge --abort` itself fails here, main is stuck mid-merge
    # and the runner cannot safely process anything else. Halt loudly
    # rather than swallowing the error with `|| true` and walking off
    # into a broken state.
    if ! git -C "$ROOT" merge --abort >/dev/null 2>&1; then
      echo "[task-queue] FATAL: orphan $branch merge conflicted AND abort failed — main stuck mid-merge"
      echo "[task-queue]   inspect: git -C $ROOT status; recover with: git -C $ROOT reset --hard HEAD"
      release_main_lock
      exit 1
    fi
    echo "[task-queue] WARNING: orphan $branch did not merge cleanly — left intact"
    echo "[task-queue]   inspect with:  git -C $ROOT diff main...$branch"
  fi
  if [[ "$stashed" == "yes" ]]; then
    local ref
    ref="$(find_our_stash_ref "$stash_msg")" || ref=""
    if [[ -n "$ref" ]]; then
      git -C "$ROOT" stash pop "$ref" >/dev/null 2>&1 \
        || echo "[task-queue] WARNING: autostash $ref not restored — recover via: git -C $ROOT stash list"
    fi
  fi
  release_main_lock
  return 0
}

# ---- CI auto-fix loop -------------------------------------------------
# Post-merge CI was a blind spot: tasks merge to main without confirmed
# CI, and a failing post-merge build went unnoticed until the next
# interactive session. The functions below close it. ci_autofix_scan runs
# between iterations of the pickup loop (time-gated), polls GitHub's
# checks API for recent merge commits, and on failure dispatches a
# follow-up brief through the same queue plumbing the runner already
# trusts — a fresh session via a fresh queued brief, never a resurrection
# of the original worker. Follow-up commits land on main through the
# same queue mechanism, not a separate PR.
#
# NOT mirrored in audit-queue/run.sh — audit merges don't gate on CI.

# Extract the task slug from a runner merge-commit subject. Handles both
# "task-queue: merge <slug>" and "task-queue: merge recovered orphan <slug>".
ci_slug_from_merge_subject() {
  local subject="$1"
  subject="${subject#task-queue: merge }"
  subject="${subject#recovered orphan }"
  printf '%s' "$subject"
}

# Number of follow-up briefs already dispatched for a fingerprint.
ci_fp_attempts() {
  cat "$CI_FP_DIR/$1.count" 2>/dev/null || echo 0
}

ci_record_fp_attempt() {
  local fp="$1" n
  n=$(ci_fp_attempts "$fp")
  echo $(( n + 1 )) > "$CI_FP_DIR/$fp.count"
}

# True if any file under queued/ at main's HEAD (including blocked/ and
# .ci-stuck markers) carries this fingerprint — i.e. a fix for this
# failure is already queued, in flight, blocked, or escalated. The
# fingerprint is embedded in the follow-up filename
# (fix-ci-<slug>-<fp8>.md), so a tree scan is the dedup check.
ci_fp_in_queue_at_head() {
  local fp="$1"
  git -C "$ROOT" ls-tree -r --name-only HEAD "$QUEUE_REL/" 2>/dev/null \
    | grep -qE -- "-${fp}\.(md$|ci-stuck\.)"
}

# Decide what to do about a (new occurrence of a) failure fingerprint:
#   skip     — a follow-up for it is already in the queue tree (queued,
#              in flight, blocked, or escalated); nothing to add.
#   dispatch — write a new follow-up brief (attempts remain).
#   escalate — attempts exhausted; commit a .ci-stuck marker brief + STUCK.
#   done     — already escalated earlier and the marker has since left the
#              tree (operator handled it); the loop stays hands-off. To
#              re-arm, clear .task-queue/ci/fingerprints/<fp>.*.
ci_disposition_for_fp() {
  local fp="$1"
  if ci_fp_in_queue_at_head "$fp"; then echo skip; return; fi
  if [[ -f "$CI_FP_DIR/$fp.escalated" ]]; then echo done; return; fi
  if (( $(ci_fp_attempts "$fp") >= CI_FIX_MAX_ATTEMPTS )); then echo escalate; return; fi
  echo dispatch
}

# Commit a NEW file into queued/ on main. Same atomicity discipline as
# mark_queue_file (clean-index pre-checks, pathspec-less commit), but
# failures defer instead of halting: the CI scan is a bolt-on — a missed
# round retries on the next scan, whereas mark_queue_file failing means
# the pickup loop itself can't advance.
# Returns 0 when the commit landed, 1 otherwise.
ci_commit_new_queue_file() {
  local path="$1" content="$2" msg="$3"
  local rel="${path#$ROOT/}"
  acquire_main_lock
  if git -C "$ROOT" rev-parse --verify --quiet MERGE_HEAD >/dev/null 2>&1 \
     || ! git -C "$ROOT" diff --cached --quiet 2>/dev/null; then
    echo "[task-queue] ci: main busy (mid-merge or staged content) — deferring $rel"
    release_main_lock
    return 1
  fi
  printf '%s' "$content" > "$path"
  if ! git -C "$ROOT" add -- "$rel" >/dev/null 2>&1 \
     || ! git -C "$ROOT" commit -m "$msg" >/dev/null 2>&1; then
    git -C "$ROOT" restore --staged -- "$rel" >/dev/null 2>&1 || true
    rm -f "$path"
    echo "[task-queue] ci: commit of $rel failed — rolled back; retrying next scan"
    release_main_lock
    return 1
  fi
  echo "[task-queue] ci: committed $rel"
  release_main_lock
  return 0
}

# All scan prerequisites present? gh (checks API), jq (parsing), an
# origin remote (somewhere for CI to run), and the brief formatter.
ci_scan_available() {
  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || return 1
  [[ -f "$CI_FORMATTER" ]] || return 1
  return 0
}

# Handle one failed check run on one merge commit: pull workflow / job /
# failed-step / log-tail details from the Actions API, fingerprint them
# via the formatter, then dispatch / escalate / skip per
# ci_disposition_for_fp. The merge sha is marked checked only once a
# durable verdict is reached, so transient errors (network, formatter)
# retry on the next scan.
ci_handle_failure() {
  local sha="$1" slug="$2" failed_run="$3"
  local details_url job_id job_json workflow job_name step run_url run_id log_snippet
  details_url=$(printf '%s' "$failed_run" | jq -r '.details_url // empty')
  workflow=""; job_name=""; step=""; run_url=""; run_id=""; job_id=""; log_snippet=""
  if [[ "$details_url" == *"/actions/runs/"*"/job/"* ]]; then
    job_id="${details_url##*/job/}"
    job_json=$(gh api "repos/{owner}/{repo}/actions/jobs/$job_id" 2>/dev/null) || job_json=""
  else
    job_json=""
  fi
  if [[ -n "$job_json" ]]; then
    workflow=$(printf '%s' "$job_json" | jq -r '.workflow_name // "unknown-workflow"')
    job_name=$(printf '%s' "$job_json" | jq -r '.name // "unknown-job"')
    step=$(printf '%s' "$job_json" | jq -r '[.steps[]? | select(.conclusion == "failure")][0].name // "unknown-step"')
    run_url=$(printf '%s' "$job_json" | jq -r '.html_url // empty')
    run_id=$(printf '%s' "$job_json" | jq -r '.run_id // empty')
    # Job logs can be MBs — byte-cap before the line tail. The formatter
    # narrows further (it centres on ##[error] markers and tail-caps);
    # the brief points the worker at the full log.
    log_snippet=$(gh api "repos/{owner}/{repo}/actions/jobs/$job_id/logs" 2>/dev/null \
                    | tail -c 200000 | tail -n 400) || log_snippet=""
  else
    # Non-Actions check (external app) or job lookup failed: fall back to
    # the check-run fields themselves.
    workflow="(external check)"
    job_name=$(printf '%s' "$failed_run" | jq -r '.name // "unknown-check"')
    step="(see check output)"
    run_url=$(printf '%s' "$failed_run" | jq -r '.html_url // empty')
    log_snippet=$(printf '%s' "$failed_run" | jq -r '[.output.title // empty, .output.summary // empty] | join("\n")')
  fi

  local payload fp
  payload=$(jq -n \
    --arg original_slug "$slug" --arg merge_sha "$sha" \
    --arg workflow "$workflow" --arg job "$job_name" --arg failed_step "$step" \
    --arg run_url "$run_url" --arg run_id "$run_id" --arg job_id "$job_id" \
    --arg log_snippet "$log_snippet" \
    '{original_slug: $original_slug, merge_sha: $merge_sha, workflow: $workflow,
      job: $job, failed_step: $failed_step, run_url: $run_url, run_id: $run_id,
      job_id: $job_id, log_snippet: $log_snippet}')
  fp=$(printf '%s' "$payload" | python3 "$CI_FORMATTER" --emit fingerprint 2>/dev/null)
  if [[ -z "$fp" ]]; then
    echo "[task-queue] ci: fingerprint formatter failed for $sha — retrying next scan"
    return 0
  fi

  local brief fname ts stuck_file
  case "$(ci_disposition_for_fp "$fp")" in
    skip)
      echo "[task-queue] ci: $slug merge ${sha:0:8} failed CI (fp $fp) — fix already queued"
      echo "failure-pending:$fp" > "$CI_CHECKED_DIR/$sha"
      ;;
    done)
      echo "[task-queue] ci: $slug merge ${sha:0:8} failed CI (fp $fp) — previously escalated; operator owns it"
      echo "failure-escalated:$fp" > "$CI_CHECKED_DIR/$sha"
      ;;
    dispatch)
      brief=$(printf '%s' "$payload" | python3 "$CI_FORMATTER" --emit brief 2>/dev/null)
      if [[ -z "$brief" ]]; then
        echo "[task-queue] ci: brief formatter failed for $sha — retrying next scan"
        return 0
      fi
      fname="fix-ci-${slug}-${fp}.md"
      if ci_commit_new_queue_file "$QUEUE_DIR/$fname" "$brief" \
           "task-queue: enqueue CI follow-up $fname"; then
        ci_record_fp_attempt "$fp"
        echo "failure-dispatched:$fp" > "$CI_CHECKED_DIR/$sha"
        echo "[task-queue] ci: $slug merge ${sha:0:8} failed CI — queued $fname (attempt $(ci_fp_attempts "$fp")/$CI_FIX_MAX_ATTEMPTS)"
      fi
      ;;
    escalate)
      ts="$(date +%Y%m%d-%H%M%S)"
      brief=$(printf '%s' "$payload" | python3 "$CI_FORMATTER" --emit brief 2>/dev/null)
      if [[ -z "$brief" ]]; then
        echo "[task-queue] ci: brief formatter failed for $sha — retrying next scan"
        return 0
      fi
      fname="fix-ci-${slug}-${fp}.ci-stuck.${ts}.md"
      if ci_commit_new_queue_file "$QUEUE_DIR/$fname" "$brief" \
           "task-queue: mark CI fingerprint $fp as ci-stuck"; then
        : > "$CI_FP_DIR/$fp.escalated"
        echo "failure-escalated:$fp" > "$CI_CHECKED_DIR/$sha"
        stuck_file="$STATE_DIR/STUCK-${ts}-ci-${fp}.md"
        cat >"$stuck_file" <<EOF
# Stuck — CI failure fingerprint $fp exhausted its retries

The CI auto-fix loop dispatched $CI_FIX_MAX_ATTEMPTS follow-up briefs for
this failure and it recurred again, so the loop stopped retrying. The
final brief was committed as
\`$QUEUE_REL/$fname\` — a \`.ci-stuck\` marker name the
runner never picks up.

- Failure fingerprint: \`$fp\`
- Latest failing merge commit: \`$sha\` (task \`$slug\`)
- Workflow / job / step: $workflow / $job_name / $step
- CI run: $run_url

## Recovery

1. Read the marker brief for the captured failure summary, or open the
   CI run above.
2. Fix the failure manually (or fix whatever made the autonomous
   attempts fail).
3. Clean up: delete the \`.ci-stuck\` marker file from \`queued/\` and
   commit; the loop stays hands-off for this fingerprint either way.
4. To re-arm autonomous retries for this fingerprint, remove
   \`.task-queue/ci/fingerprints/$fp.count\` and \`$fp.escalated\`.
EOF
        echo "[task-queue] ci: fingerprint $fp recurred after $CI_FIX_MAX_ATTEMPTS follow-ups — escalated (.ci-stuck)"
        echo "[task-queue] ci: details: $stuck_file"
      fi
      ;;
  esac
}

# Classify one merge commit's CI status. Marks the sha checked only on a
# durable verdict (success / no-checks / failure handled); everything
# else — not pushed yet, checks still running, API hiccup — leaves it
# pending for the next scan.
ci_check_merge_commit() {
  local sha="$1" ctime="$2" slug="$3"
  local checks total incomplete failed_run failed_count now
  # An unknown sha (not pushed yet) or a network failure errors here —
  # both retry on a later scan.
  checks=$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100" 2>/dev/null) || return 0
  total=$(printf '%s' "$checks" | jq -r '.total_count // 0' 2>/dev/null) || return 0
  if (( total == 0 )); then
    # Pushed, but no checks attached. CI may still be queueing — only
    # conclude "no CI" after the grace period.
    now=$(date +%s)
    if (( now - ctime >= CI_ZERO_CHECK_GRACE_S )); then
      echo "no-checks" > "$CI_CHECKED_DIR/$sha"
    fi
    return 0
  fi
  incomplete=$(printf '%s' "$checks" | jq '[.check_runs[] | select(.status != "completed")] | length')
  (( incomplete > 0 )) && return 0   # still running — recheck later
  failed_count=$(printf '%s' "$checks" | jq '[.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out")] | length')
  if (( failed_count == 0 )); then
    echo "success" > "$CI_CHECKED_DIR/$sha"
    return 0
  fi
  # Handle the first failed check run (sorted by name — deterministic).
  # Additional failures usually share a root cause; any that don't will
  # resurface on the follow-up's own post-merge CI run.
  failed_run=$(printf '%s' "$checks" | jq -c '[.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out")] | sort_by(.name) | .[0]')
  if (( failed_count > 1 )); then
    echo "[task-queue] ci: ${sha:0:8} has $failed_count failed check runs — handling the first; the rest resurface on the follow-up's CI"
  fi
  ci_handle_failure "$sha" "$slug" "$failed_run"
}

# The scan entry point, called at the pickup loop's iteration boundary
# and inside its idle poll. Time-gated internally so the 5s poll cadence
# doesn't hammer the API; CI_SCAN_INTERVAL_S=0 disables entirely.
ci_autofix_scan() {
  (( CI_SCAN_INTERVAL_S > 0 )) || return 0
  local now sha ctime subject slug
  now=$(date +%s)
  (( now - CI_LAST_SCAN_EPOCH >= CI_SCAN_INTERVAL_S )) || return 0
  CI_LAST_SCAN_EPOCH=$now
  if ! ci_scan_available; then
    if (( CI_UNAVAILABLE_LOGGED == 0 )); then
      CI_UNAVAILABLE_LOGGED=1
      echo "[task-queue] ci: scan disabled — needs gh, jq, python3, an 'origin' remote, and $CI_FORMATTER"
    fi
    return 0
  fi
  while IFS=$'\t' read -r sha ctime subject; do
    [[ -z "$sha" ]] && continue
    [[ -f "$CI_CHECKED_DIR/$sha" ]] && continue
    slug="$(ci_slug_from_merge_subject "$subject")"
    ci_check_merge_commit "$sha" "$ctime" "$slug"
  done < <(git -C "$ROOT" log main --grep='^task-queue: merge ' \
             --format='%H%x09%ct%x09%s' -n "$CI_MERGE_SCAN_LIMIT" 2>/dev/null)
  return 0
}

# When this file is sourced (by the test harness — see test-run.sh)
# rather than executed, stop here: every function above is now defined,
# but the polling loop and its side effects (cd, banner, spawning
# workers) must not run.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0
fi

# ---- Subcommands, detach, launch (executed, not sourced) -------------

# `stop` and `recover` are operator one-shots: they act and exit without
# entering the loop.
case "${1:-}" in
  stop)
    mkdir -p "$STATE_DIR"
    : > "$STOP_SENTINEL"
    echo "[task-queue] stop requested — touched $STOP_SENTINEL"
    echo "[task-queue] every running task-queue runner exits at its next iteration boundary"
    exit 0
    ;;
  recover)
    cd "$ROOT"
    echo "[task-queue] reconciling orphaned task-queue/* branches (recover mode)"
    reconcile_orphans recover
    exit 0
    ;;
  -h|--help|help)
    cat <<EOF
Usage: bash run.sh [--foreground]   start the autonomous task-queue runner
       bash run.sh stop             ask every running runner to stop gracefully
       bash run.sh recover          merge + clean up orphaned task-queue/* branches
       bash run.sh --help           this message

By default the runner detaches from the launching terminal (re-execs under
\`setsid script\`, logging to .task-queue/runner-<ts>.out) so it survives the
terminal closing. --foreground keeps it in the current terminal with live
output, for debugging the runner itself.
EOF
    exit 0
    ;;
esac

FOREGROUND=0
[[ "${1:-}" == "--foreground" ]] && FOREGROUND=1

# Detach unless --foreground or already detached. The runner re-execs
# itself under `setsid script`: `setsid` puts it in a new session with
# no controlling terminal, so closing the launching terminal cannot
# SIGHUP it; `script` allocates a fresh pty, which the `claude --bg`
# workers still need during their Agent View / Remote Control
# registration handshake. Runner output is captured to the runner log.
if [[ "${TASK_QUEUE_DETACHED:-0}" != "1" && $FOREGROUND -eq 0 ]]; then
  mkdir -p "$STATE_DIR"
  RUNNER_LOG="$STATE_DIR/runner-$(date +%Y%m%d-%H%M%S)-$$.out"
  TASK_QUEUE_DETACHED=1 setsid script -qec "bash $(printf '%q' "$SELF")" /dev/null \
    >"$RUNNER_LOG" 2>&1 </dev/null &
  echo "[task-queue] runner detached (pid $!)"
  echo "[task-queue] log:  $RUNNER_LOG   (tail -f to watch)"
  echo "[task-queue] stop: bash $SELF stop"
  exit 0
fi

# ---- Detached (or --foreground) runner instance ----------------------

# Signal handlers REQUEST a stop; the loop performs the exit at its
# iteration boundary (see request_stop / should_stop). HUP is trapped
# too as a backstop — detachment already prevents the launching
# terminal from delivering it.
trap request_stop INT TERM HUP

# Clear any stale stop sentinel from a previous run. A runner that is
# itself stopping leaves the sentinel in place so sibling runners still
# draining also observe it; only a fresh launch clears it.
rm -f "$STOP_SENTINEL"

cd "$ROOT"

# Expand the prompt's include directives once, up front. A broken include
# has to stop the launch here, before any worktree or branch exists —
# never surface later as a worker missing part of its instructions.
if ! WORKER_PROMPT="$(render_worker_prompt)"; then
  echo "[task-queue] could not render the worker prompt from $PROMPT_FILE — aborting"
  exit 1
fi

# Reconcile orphaned branches before taking new work — report only.
# Recovery is the explicit `run.sh recover` action, never automatic.
reconcile_orphans report

echo "[task-queue] watching $QUEUE_DIR"
echo "[task-queue] worktrees:   $WORKTREE_DIR"
if [[ -n "$TASK_TIMEOUT" ]]; then
  echo "[task-queue] timeout per task: $TASK_TIMEOUT  (set TASK_QUEUE_TIMEOUT= to disable)"
else
  echo "[task-queue] timeout per task: none  (set TASK_QUEUE_TIMEOUT=60m to enable)"
fi
echo "[task-queue] poll interval: ${POLL_SECONDS}s   (override TASK_QUEUE_POLL_SECONDS)"
if (( CI_SCAN_INTERVAL_S > 0 )); then
  echo "[task-queue] ci scan: every ${CI_SCAN_INTERVAL_S}s, escalate after $CI_FIX_MAX_ATTEMPTS follow-ups   (TASK_QUEUE_CI_SCAN_SECONDS=0 disables)"
else
  echo "[task-queue] ci scan: disabled   (set TASK_QUEUE_CI_SCAN_SECONDS=120 to enable)"
fi
echo "[task-queue] background sessions named: <task-slug>   (local: 'claude agents' / 'claude logs <id>'; remote: claude.ai/code + mobile via Remote Control)"
echo "[task-queue] stop: 'bash $SELF stop', or one SIGINT/SIGTERM (a second = fast stop)"
echo

while true; do
  # Iteration boundary. A pending stop (signal flag or sentinel) is
  # honored HERE, between iterations — never mid-merge. This is the
  # boundary the signal handler defers the exit to.
  if should_stop; then
    echo "[task-queue] stop observed — exiting cleanly"
    exit 0
  fi

  # CI auto-fix sub-loop: between iterations (and during idle polling
  # below), check recent merge commits' CI and queue follow-up briefs
  # for failures. Time-gated internally, so calling it every poll is
  # cheap.
  ci_autofix_scan

  # Poll until we can CLAIM a task — not merely until one exists. With
  # sibling runners active, an eligible task may exist but be held by
  # another runner; claim_next_task walks past those to the first free
  # one, sets TASK_FILE / SLUG, and leaves the per-task lock (fd 9) held
  # for the whole iteration (released at the bottom of the loop body).
  while ! claim_next_task; do
    if should_stop; then
      echo "[task-queue] stop observed — exiting cleanly"
      exit 0
    fi
    ci_autofix_scan
    sleep "$POLL_SECONDS"
  done

  BRANCH="task-queue/$SLUG"
  WORKTREE="$WORKTREE_DIR/$SLUG"
  TS="$(date +%Y%m%d-%H%M%S)"
  LOG_FILE="$LOG_DIR/$TS-$SLUG.log"

  # If a worktree or branch already exists for this slug, refuse to clobber
  # it — it's almost certainly forensic state from a previous .crashed /
  # .abandoned-wip / .merge-failed / .partial run that a human renamed back to .md to
  # re-queue without cleaning up the worktree first. Mark this attempt
  # .merge-failed so the loop doesn't infinite-retry, and instruct the
  # human how to recover.
  if [[ -d "$WORKTREE" ]] || git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "[task-queue] ERROR: $WORKTREE or branch $BRANCH already exists"
    echo "[task-queue] Likely leftover forensic state, or an orphaned run. Recover with:"
    echo "[task-queue]   - bash $SELF recover   (merges a complete orphan, cleans up), or"
    echo "[task-queue]   - inspect $WORKTREE/STUCK.md, then 'git worktree remove --force"
    echo "[task-queue]     $WORKTREE' + 'git branch -D $BRANCH', then rename the queue file"
    echo "[task-queue]     back to .md to re-pick."
    # The only record here is whatever the PREVIOUS run's worker left in
    # the leftover worktree, and it may not exist at all — point at it
    # only when it does.
    LEFTOVER_RECORD=""
    [[ -f "$WORKTREE/STUCK.md" ]] && LEFTOVER_RECORD="$WORKTREE/STUCK.md"
    mark_queue_file "$TASK_FILE" "merge-failed" "$TS" "$LEFTOVER_RECORD"
    flock -u 9; exec 9>&-
    continue
  fi

  echo "[task-queue] $(date -Iseconds) picked $(basename "$TASK_FILE")"
  echo "[task-queue] creating worktree $WORKTREE on branch $BRANCH (off main)"
  printf '%s picked=%s slug=%s\n' "$(date -Iseconds)" "$TASK_FILE" "$SLUG" >> "$LOG_FILE"

  if ! git worktree add -b "$BRANCH" "$WORKTREE" main >>"$LOG_FILE" 2>&1; then
    echo "[task-queue] git worktree add failed — see $LOG_FILE"
    # No worktree was created, so no record exists — the log is all there is.
    mark_queue_file "$TASK_FILE" "merge-failed" "$TS" ""
    flock -u 9; exec 9>&-
    continue
  fi

  # Populate submodules. `git worktree add` writes .gitmodules and an EMPTY
  # submodule directory — it never checks a submodule out — and in consuming
  # repos that reach this skill through workshop, every shared skill in
  # .claude/skills/ is a symlink into that directory. Skip this and the
  # worker gets dangling links: no /task-* commands, no templates, a pytest
  # collection error where tests import devtools.scripts — and the failure is
  # silent in the worst way: a dangling symlink is not a failure until
  # something follows it, so the runner exits 0 over a worker that never had
  # its instructions. The runner is unaffected either way (it resolves
  # $SKILL_DIR from the main tree); it is the worker's world that is
  # stripped. In fleet repos with no submodules this no-ops harmlessly.
  #
  # Mirror: the sibling audit-queue runner in clients/pia-maker
  # (.claude/skills/audit-queue/run.sh) carries this same fix — keep the two
  # in step. Reference implementation: .claude/hooks/setup-worktree.sh.
  if ! git -C "$WORKTREE" submodule update --init >>"$LOG_FILE" 2>&1; then
    echo "[task-queue] git submodule update --init failed in $WORKTREE — see $LOG_FILE"
    echo "[task-queue] Refusing to spawn a worker into a worktree with dangling"
    echo "[task-queue] skill symlinks. Check network reachability to the submodule"
    echo "[task-queue] remote, then re-run."
    cleanup_worktree "$WORKTREE" "$BRANCH"
    # The worktree -- and any STUCK marker in it -- is gone with the teardown,
    # so no record exists; the log is all there is, as with the worktree-add
    # failure above.
    mark_queue_file "$TASK_FILE" "merge-failed" "$TS" ""
    flock -u 9; exec 9>&-
    continue
  fi

  stage_shared_paths "$WORKTREE"

  # Capture the branch's starting commit so we can detect "did the worker
  # actually commit anything" later. Equivalent to the merge-base with
  # main at spawn time.
  START_SHA="$(git -C "$WORKTREE" rev-parse HEAD)"

  # The task path is given to the worker relative to the repo root so the
  # `git rm`/`git mv` commands in initial-prompt.md work unchanged.
  TASK_REL_PATH="$QUEUE_REL/$(basename "$TASK_FILE")"

  echo "[task-queue] $(date -Iseconds) launching claude (log: $(basename "$LOG_FILE"))"

  # `--bg --name <slug>` dispatches the worker through Claude Code's
  # Agent View daemon (shipped 2026-05-11). The CLI prints
  # `backgrounded · <short-id>` and returns within a few seconds while
  # the session keeps running under the daemon. We capture the short id,
  # then block on the worker via `wait_for_bg_session`, which polls the
  # daemon's per-session state file.
  #
  # `--remote-control "task-queue: <slug>"` attaches Remote Control to the
  # SAME spawn, and it is load-bearing. Agent View and Remote Control are
  # independent surfaces: `--bg` alone makes the worker visible only to the
  # LOCAL `claude agents` / `claude logs`, never to claude.ai/code or the
  # Claude mobile app. A bare-`--bg` worker's AskUserQuestion /
  # PushNotification calls cannot reach the phone — the tool result reads
  # "Mobile push not sent — Remote Control inactive". `--remote-control`
  # restores "drop a task, walk away, answer from your phone". The two
  # flags compose: the worker is backgrounded AND Remote-Control-attached,
  # and `wait_for_bg_session` polling is unchanged. (A 2026-05-16 migration
  # dropped `--rc` on a verification that wrongly cleared bare `--bg` for
  # mobile push; see the 2026-05-22 kaizen entry.)
  #
  # `--permission-mode bypassPermissions` skips every permission check —
  # tool calls, Bash, MCP, edits. Required for hands-off operation. Only
  # safe in a sandboxed host (dev container, VM). If you must run on a
  # bare workstation, switch to acceptEdits and accept the prompts.
  #
  # Timeout is enforced inside `wait_for_bg_session` (it calls
  # `claude stop` after the configured duration). The classic `timeout(1)`
  # wrapper is gone — it only timed the dispatch call, which exits in
  # seconds and never trips the limit.
  #
  # We spawn from inside the worktree so the worker's cwd is its own
  # isolated tree. The `--worktree` Claude Code flag is intentionally
  # NOT used here — its exit-time prompts would hang an unattended loop,
  # and the runner needs to merge before any cleanup decision anyway.
  DISPATCH_OUT=$(mktemp)
  # Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
  # Embed the task-job params directly in the prompt body. `claude --bg`
  # does not propagate the runner's env vars to the daemon-spawned worker;
  # the env-var assignments below are kept as defense-in-depth.
  DISPATCH_PROMPT="## Task job (this iteration's parameters)

Use these values literally. Do not infer paths from the worktree slug.

- Task path: \`$TASK_REL_PATH\`
- Branch:    \`$BRANCH\`
- Self-terminate script (if you choose to use it): \`$SELF_TERMINATE_SCRIPT\`

---

$WORKER_PROMPT"
  (
    cd "$WORKTREE"
    TASK_QUEUE_TASK_PATH="$TASK_REL_PATH" \
    TASK_QUEUE_SLUG="$SLUG" \
    TASK_QUEUE_BRANCH="$BRANCH" \
    TASK_QUEUE_SELF_TERMINATE="$SELF_TERMINATE_SCRIPT" \
      claude \
        --bg --name "$SLUG" \
        ${WORKER_MODEL:+--model "$WORKER_MODEL"} \
        ${WORKER_EFFORT:+--effort "$WORKER_EFFORT"} \
        --remote-control "task-queue: $SLUG" \
        --permission-mode bypassPermissions \
        "$DISPATCH_PROMPT"
  ) 2>&1 | tee "$DISPATCH_OUT"
  DISPATCH_EXIT=${PIPESTATUS[0]}

  if [[ $DISPATCH_EXIT -ne 0 ]]; then
    echo "[task-queue] claude --bg failed to dispatch (exit $DISPATCH_EXIT) — halting"
    printf '%s dispatch-failed exit=%d\n' "$(date -Iseconds)" "$DISPATCH_EXIT" >> "$LOG_FILE"
    rm -f "$DISPATCH_OUT"
    mark_queue_file "$TASK_FILE" "dispatch-failed" "$TS"
    flock -u 9; exec 9>&-
    continue
  fi

  SHORT_ID=$(grep -oE '^backgrounded · [a-f0-9]+' "$DISPATCH_OUT" | head -1 | awk '{print $3}')
  rm -f "$DISPATCH_OUT"

  if [[ -z "$SHORT_ID" ]]; then
    echo "[task-queue] could not parse session id from claude --bg output — halting"
    printf '%s dispatch-unparseable\n' "$(date -Iseconds)" >> "$LOG_FILE"
    mark_queue_file "$TASK_FILE" "dispatch-failed" "$TS"
    flock -u 9; exec 9>&-
    continue
  fi

  TIMEOUT_S=$(parse_timeout_to_seconds "$TASK_TIMEOUT")
  echo "[task-queue] $(date -Iseconds) dispatched bg session $SHORT_ID; waiting"
  wait_for_bg_session "$SHORT_ID" "$TIMEOUT_S"
  EXIT_CODE=$?

  echo "[task-queue] $(date -Iseconds) claude exited (code $EXIT_CODE)"
  printf '%s exit=%d short_id=%s\n' "$(date -Iseconds)" "$EXIT_CODE" "$SHORT_ID" >> "$LOG_FILE"

  # Examine the worktree's state to decide what to do next.
  END_SHA="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "$START_SHA")"
  ADVANCED=0
  if [[ "$END_SHA" != "$START_SHA" ]]; then
    ADVANCED=1
  fi
  # Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
  # "Dirty" means TRACKED files differ from HEAD (staged or unstaged).
  # Crucially we do NOT use `git status --porcelain` because that also
  # reports untracked files — and the runner itself creates untracked
  # symlinks (.env, .venv, node_modules, data) in the worktree as part
  # of `stage_shared_paths`. Pytest, build steps, etc. add more
  # untracked artifacts. None of that should count as "the worker left
  # uncommitted work." `git diff --quiet HEAD` looks only at tracked
  # files vs HEAD, which is exactly the question we want answered.
  DIRTY=""
  if ! git -C "$WORKTREE" diff --quiet HEAD 2>/dev/null; then
    DIRTY="yes"
  fi

  case $EXIT_CODE in
    130)
      # User-initiated Ctrl-C. Don't touch anything — leave the worktree,
      # branch, and queue file as-is. Re-running the loop will pick the
      # task up again. Exit cleanly so the next Ctrl-C doesn't stack.
      echo "[task-queue] interrupted — leaving worktree $WORKTREE intact"
      printf '%s interrupted exit=%d\n' "$(date -Iseconds)" "$EXIT_CODE" >> "$LOG_FILE"
      flock -u 9; exec 9>&-
      exit 0
      ;;
    0|143)
      # Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
      # Runner-side queue-file removal — the FALLBACK. The worker's prompt
      # instructs it to close out its own brief (repair inbound markdown
      # links, then `git rm "$TASK_QUEUE_TASK_PATH"`) in its final
      # in-branch commit, where an agent with context can satisfy a
      # whole-tree doc-links gate semantically; the normal case is
      # therefore the skip branch below. This block covers workers that
      # stop without doing so. It succeeds whenever the brief has no
      # inbound links; when links exist, the removal commit fails that
      # gate here and the iteration lands in the loud marker path
      # (mark_queue_file — which runs the same repair mechanically, so a
      # failed task no longer wedges the runner either). Whether the
      # worker self-terminated cleanly (state=done) or the runner stopped
      # it after a stall (STALL_FORCED=1), the fallback removal happens
      # here. Gated on ADVANCED so an empty branch (worker bailed before
      # doing real work) never strips the queue file. Idempotent against
      # (a) the normal closure where the worker removed the brief itself
      # and (b) the "blocked" path where the worker moved the file to
      # queued/blocked/: both leave the file absent from its original
      # queued/ path on the branch tip, which we detect with
      # `git cat-file -e HEAD:<path>`.
      #
      # Guarded on worktree_busy first: staging a deletion into a tree that
      # is mid-write is the 2026-07-31 teardown race. Forcing DIRTY here
      # routes the iteration down the existing abandoned-wip path — brief
      # marked, worktree kept for inspection, nothing merged — instead of
      # racing whatever is still writing.
      if worktree_busy "$WORKTREE"; then
        echo "[task-queue] queue-file: worktree is mid-write ($WORKTREE_BUSY_REASON) — refusing to remove the brief"
        printf '%s worktree-busy: %s\n' "$(date -Iseconds)" "$WORKTREE_BUSY_REASON" >> "$LOG_FILE"
        DIRTY="yes"
      elif [[ $ADVANCED -eq 1 ]]; then
        if ! git -C "$WORKTREE" cat-file -e "HEAD:$TASK_REL_PATH" 2>/dev/null; then
          echo "[task-queue] queue-file: $TASK_REL_PATH already removed or moved on branch — skipping"
        else
          rm_note="runner"
          (( STALL_FORCED == 1 )) && rm_note="runner (after stall)"
          echo "[task-queue] queue-file: removing $TASK_REL_PATH via $rm_note"
          if git -C "$WORKTREE" rm -- "$TASK_REL_PATH" >>"$LOG_FILE" 2>&1; then
            if git -C "$WORKTREE" commit -m "chore(task-queue): remove completed task $TASK_REL_PATH" >>"$LOG_FILE" 2>&1; then
              echo "[task-queue] queue-file: removal commit landed"
            else
              echo "[task-queue] queue-file: removal commit failed — see $LOG_FILE"
            fi
          else
            echo "[task-queue] queue-file: git rm FAILED — see $LOG_FILE; branch will merge without removing queue file"
          fi
          # Re-check ADVANCED/DIRTY after the rm commit.
          END_SHA="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "$START_SHA")"
          ADVANCED=0
          [[ "$END_SHA" != "$START_SHA" ]] && ADVANCED=1
          DIRTY=""
          git -C "$WORKTREE" diff --quiet HEAD 2>/dev/null || DIRTY="yes"
        fi
      else
        echo "[task-queue] queue-file: no commits on branch — leaving queue file intact"
      fi

      if [[ $ADVANCED -eq 1 && -z "$DIRTY" ]]; then
        # Success signal received — but verify tracked state agrees
        # before merging. A disagreement (brief still on disk, broken
        # test collection, leftover STUCK.md) marks the brief .partial
        # and keeps the worktree for forensics instead of merging a
        # half-done task into main.
        if ! validate_worker_state "$WORKTREE" "$TASK_REL_PATH" "$START_SHA"; then
          echo "[task-queue] worker reported success but tracked state disagrees: $VALIDATE_FAILURE"
          echo "[task-queue] marking partial and keeping worktree"
          mark_queue_file "$TASK_FILE" "partial" "$TS"
          cat >"$WORKTREE/STUCK.md" <<EOF
# Partial — success signal disagreed with tracked state

The worker ended its turn as if the task were complete, but the runner's
post-exit validation failed:

**Failed check:** $VALIDATE_FAILURE

- Worktree: \`$WORKTREE\`
- Branch:   \`$BRANCH\`
- Original queue file: \`$TASK_REL_PATH\` (renamed on main with a \`.partial.$TS.md\` suffix)
- Run log: \`$LOG_FILE\`

The worker's commits are intact on \`$BRANCH\` — nothing was merged.
Inspect the worktree (\`git log\`, \`git status\`, run the tests) to decide
whether the work is actually complete:

- **Work is fine** (validation failure was environmental): merge manually
  with \`git -C $ROOT merge --no-ff $BRANCH\`, or run \`bash $SELF recover\`
  (this branch will be reported as an orphan at the next launch). Then
  delete the \`.partial.$TS.md\` marker file on main and clean up the
  worktree and branch.
- **Work is incomplete**: fix it up here (or discard the branch), rename
  the \`.partial.$TS.md\` marker back to \`$(basename "$TASK_REL_PATH")\`
  and commit to re-queue, and \`git worktree remove --force $WORKTREE\`
  first so the retry doesn't collide with this worktree.
EOF
          claude stop "$SHORT_ID" >/dev/null 2>&1 || true
          printf '%s partial: %s (%s)\n' "$(date -Iseconds)" "$BRANCH" "$VALIDATE_FAILURE" >> "$LOG_FILE"
          flock -u 9; exec 9>&-
          continue
        fi

        # Success path: worker committed and exited clean. Merge the
        # worker's branch into main with --no-ff to create a merge
        # commit that groups the task's commits as one unit.
        # Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
        # We deliberately do NOT rebase before merging. On this
        # devcontainer's filesystem, `git rebase` (both the default
        # merge backend AND the --apply backend) spuriously aborts
        # mid-replay with "Your local changes would be overwritten by
        # merge" on a provably-clean worktree, at a non-deterministic
        # commit each run. `git merge --no-ff` uses git's `ort` merge
        # engine directly without the rewind+replay intermediate state
        # that triggers the bug. See kaizen entries dated 2026-05-14
        # and 2026-05-15.

        SLUG_BASE="$(basename "$TASK_FILE" .md)"

        # Everything from here through cleanup_worktree mutates `main` or
        # its index — autostash, merge, stash pop, marker commits. Take
        # the host-wide lock so a sibling runner's merge cannot interleave
        # with our sequence. release_main_lock is called on EVERY exit
        # path of this block: the stash-failed and merge-failed `continue`
        # paths, the two autostash STUCK `exit 1` paths, and the success
        # tail below.
        echo "[task-queue] $(date -Iseconds) acquiring main lock for merge"
        acquire_main_lock
        echo "[task-queue] holding main lock; merging"

        # Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
        # Pre-merge wedge gate. Before touching main, refuse if it is
        # already mid-merge or carries unmerged/conflicted index entries —
        # i.e. a state we cannot safely autostash our way out of and from
        # which `git merge --abort` would itself fail. This catches a main
        # wedged by a sibling runner (the 2026-06-17 cascade, where the
        # audit-queue runner walked into a task-queue-wedged main and died
        # on `stash push … needs merge`) and surfaces it HERE instead of
        # compounding it. Ambient *clean* WIP (staged or unstaged, no
        # conflicts) is NOT a wedge — it is autostashed below as usual.
        if git -C "$ROOT" rev-parse --verify --quiet MERGE_HEAD >/dev/null 2>&1 \
           || [[ -n "$(git -C "$ROOT" ls-files --unmerged 2>/dev/null)" ]]; then
          WEDGE_PATHS="$(git -C "$ROOT" ls-files --unmerged 2>/dev/null \
                          | awk '{print $4}' | sort -u | paste -sd' ' - || true)"
          [[ -z "$WEDGE_PATHS" ]] && WEDGE_PATHS="(MERGE_HEAD set; see git status)"
          STUCK_FILE="$STATE_DIR/STUCK-${TS}-${SLUG}-main-wedged.md"
          cat >"$STUCK_FILE" <<EOF
# Stuck — main already wedged before merge

The task-queue runner was about to merge \`$BRANCH\` into \`main\` but
found \`main\` already in an unmergeable state (\`MERGE_HEAD\` set and/or
unmerged index paths) — most likely left by another process. The runner
did NOT start its merge, to avoid compounding the wedge.

- Conflicted/unmerged paths: \`$WEDGE_PATHS\`
- Worktree: \`$WORKTREE\`
- Branch:   \`$BRANCH\`
- Run log:  \`$LOG_FILE\`

## Recovery

1. \`cd $ROOT && git status\` — inspect the in-progress merge / unmerged
   paths and find which process left them.
2. Resolve or back out that merge (\`git merge --abort\`, or
   \`git reset --hard HEAD\` once you've confirmed no un-stashed WIP is at
   risk), then check \`git stash list\` for any autostash to restore.
3. The worker's commits live on \`$BRANCH\`. This task was marked
   merge-failed; re-queue it (or merge \`$BRANCH\` manually) once main is
   clean.
EOF
          echo "[task-queue] FATAL: main is already wedged ($WEDGE_PATHS) — refusing to merge"
          echo "[task-queue] details: $STUCK_FILE"
          mark_queue_file "$TASK_FILE" "merge-failed" "$TS" "$STUCK_FILE"
          release_main_lock
          flock -u 9; exec 9>&-
          continue
        fi

        # Mirror: .claude/skills/audit-queue/run.sh — keep these in sync.
        # Autostash main's dirty WT before the merge, restore after.
        # `git merge --no-ff` refuses if ANY file in main's WT has
        # uncommitted changes AND the merge would touch it — including
        # files only "carried forward" from main (e.g., files newly
        # added on main during the task, with WIP on top of them).
        # See 2026-05-15 kaizen entry for the failure case that
        # motivated this. `git pull --autostash` does the same dance
        # for rebase/pull; we replicate it manually around merge.
        #
        # --include-untracked AND the staged index: a bare `git stash push`
        # leaves staged-only and untracked changes behind. Any staged WIP
        # left in the index would later defeat `git merge --abort`
        # (≈ `git reset --merge`), which refuses when staged changes
        # outside the merge would be lost — the exact defect that wedged
        # main on 2026-06-17. `git diff --quiet HEAD` already flags both
        # staged and unstaged tracked changes; we additionally stash
        # untracked files and then VERIFY the index is empty post-stash.
        STASHED="no"
        # Include this runner's PID in the stash message so concurrent
        # runners (parallel task-queue runners, or task-queue + audit-queue)
        # produce uniquely-identifiable stashes. Used by find_our_stash_ref
        # below to pop the right entry, not just stash@{0}.
        STASH_MSG="task-queue: autostash before merging ${SLUG_BASE} [pid=$$]"
        if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null \
           || [[ -n "$(git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
          if git -C "$ROOT" stash push --include-untracked -m "$STASH_MSG" >>"$LOG_FILE" 2>&1; then
            STASHED="yes"
            echo "[task-queue] stashed main's WIP before merge"
          else
            echo "[task-queue] stash push failed — see $LOG_FILE; marking merge-failed"
            # No merge was attempted and no record written — log only.
            mark_queue_file "$TASK_FILE" "merge-failed" "$TS" ""
            release_main_lock
            flock -u 9; exec 9>&-
            continue
          fi
        fi

        # Verify the stash actually cleared the index. If staged content
        # somehow survives the stash, a later `git merge --abort` could
        # refuse — so bail safely now rather than risk a wedge.
        if ! git -C "$ROOT" diff --cached --quiet 2>/dev/null; then
          echo "[task-queue] index not clean after autostash — refusing to merge; marking merge-failed"
          if [[ "$STASHED" == "yes" ]]; then
            OUR_STASH_REF=$(find_our_stash_ref "$STASH_MSG") || OUR_STASH_REF=""
            [[ -n "$OUR_STASH_REF" ]] && git -C "$ROOT" stash pop "$OUR_STASH_REF" >>"$LOG_FILE" 2>&1 || true
          fi
          # No merge was attempted and no record written — log only.
          mark_queue_file "$TASK_FILE" "merge-failed" "$TS" ""
          release_main_lock
          flock -u 9; exec 9>&-
          continue
        fi

        # Refresh main's index stat cache before merging to defend
        # against the same stat-cache drift that may have triggered
        # the rebase bug.
        git -C "$ROOT" update-index --refresh >/dev/null 2>&1 || true
        # Capture main's pre-merge HEAD so a failed `git merge --abort`
        # can be backstopped with `git reset --hard $PRE_MERGE_SHA` —
        # but only after we've confirmed any real WIP is safely stashed
        # (STASHED/empty index, above), so the reset can't destroy
        # un-stashed user work. See AC3 / the 2026-06-17 incident.
        PRE_MERGE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
        MERGE_MSG="task-queue: merge ${SLUG_BASE}"
        echo "[task-queue] merging $BRANCH into main (--no-ff)"
        if ! git -C "$ROOT" merge --no-ff "$BRANCH" -m "$MERGE_MSG" >>"$LOG_FILE" 2>&1; then
          # FIRST statement in this block, and it has to stay first: the
          # abort below clears the unmerged index entries, and the record
          # is not written until ~70 lines further down. Capturing any
          # later yields an empty list that reads as "no conflicts".
          CONFLICT_PATHS="$(capture_conflict_paths "$ROOT")"
          echo "[task-queue] merge failed on $BRANCH ($CONFLICT_PATHS) — aborting; leaving worktree for human"
          # If `merge --abort` itself fails, main is stuck mid-merge:
          # MERGE_HEAD is set, the index has unmerged paths, and no
          # subsequent git write on main will succeed. Continuing past
          # this point — through `mark_queue_file`, through the next
          # iteration's claim — is what produced the 2026-05-22 infinite
          # loop. We first retry the abort with a hard fallback to
          # `git reset --hard $PRE_MERGE_SHA`: the autostash already holds
          # any real WIP (verified above), so the reset restores main to
          # its exact pre-merge HEAD without losing user work. Only if
          # BOTH the abort and the reset fail do we halt with a STUCK
          # record that names every path the operator needs to clean up.
          if ! git -C "$ROOT" merge --abort >>"$LOG_FILE" 2>&1 \
             && ! git -C "$ROOT" reset --hard "$PRE_MERGE_SHA" >>"$LOG_FILE" 2>&1; then
            STUCK_FILE="$STATE_DIR/STUCK-${TS}-${SLUG}-abort-failed.md"
            cat >"$STUCK_FILE" <<EOF
# Stuck — git merge --abort AND reset --hard failed

The task-queue runner attempted to merge \`$BRANCH\` into \`main\`, hit
a conflict, and then could neither \`git merge --abort\` nor
\`git reset --hard $PRE_MERGE_SHA\` back main out. \`main\` is now stuck
mid-merge — \`MERGE_HEAD\` is set, the index has unmerged paths, and no
further git writes on \`main\` will succeed until you resolve it. (This
should be extremely rare: the runner autostashed any WIP before merging,
so the reset had a safe target.)

- Pre-merge HEAD: \`$PRE_MERGE_SHA\`
- Worktree: \`$WORKTREE\`
- Branch:   \`$BRANCH\`
- Run log:  \`$LOG_FILE\`

## Recovery

1. \`cd $ROOT && git status\` — confirm \`MERGE_HEAD\` is set and note
   the unmerged paths.
2. Back main out manually: \`git merge --abort\`, or escalate to
   \`git reset --hard $PRE_MERGE_SHA\` (restores main to its exact
   pre-merge HEAD; no main WIP is at risk — the runner autostashed it
   before merging).
3. Restore the autostash if present: look for
   "task-queue: autostash before merging ${SLUG_BASE}" in
   \`git stash list\`.
4. The worker's commits live on \`$BRANCH\`. If you want the work,
   re-merge it manually (\`git merge --no-ff $BRANCH\`); otherwise
   delete the branch and let the task get re-queued.
5. Clean up: \`git worktree remove --force $WORKTREE\` and
   \`git branch -D $BRANCH\`.
EOF
            echo "[task-queue] FATAL: merge --abort AND reset --hard failed — main is stuck mid-merge"
            echo "[task-queue] details: $STUCK_FILE"
            release_main_lock
            flock -u 9; exec 9>&-
            exit 1
          fi
          # Try to restore the autostash so the user's WIP isn't trapped.
          # Use find_our_stash_ref so we pop OUR entry, not stash@{0}.
          if [[ "$STASHED" == "yes" ]]; then
            OUR_STASH_REF=$(find_our_stash_ref "$STASH_MSG") || OUR_STASH_REF=""
            if [[ -z "$OUR_STASH_REF" ]]; then
              echo "[task-queue] WARNING: autostash not found in stash list; recover with: git -C $ROOT stash list"
            elif ! git -C "$ROOT" stash pop "$OUR_STASH_REF" >>"$LOG_FILE" 2>&1; then
              echo "[task-queue] WARNING: failed to pop autostash $OUR_STASH_REF; recover with: git -C $ROOT stash list / pop"
            fi
          fi
          STUCK_FILE="$STATE_DIR/STUCK-${TS}-${SLUG}-merge-failed.md"
          write_merge_failed_record "$STUCK_FILE" "$BRANCH" "$WORKTREE" \
            "$TASK_REL_PATH" "$TS" "$LOG_FILE" "$CONFLICT_PATHS" "$ROOT"
          echo "[task-queue] details: $STUCK_FILE"
          mark_queue_file "$TASK_FILE" "merge-failed" "$TS" "$STUCK_FILE"
          release_main_lock
          flock -u 9; exec 9>&-
          continue
        fi

        # Merge succeeded. Restore main's WIP from the autostash.
        # If the pop conflicts, the merge has already landed on main
        # and we halt with STUCK.md so the next iteration doesn't pile
        # another stash on top of an unresolved one.
        # Use find_our_stash_ref so we pop OUR entry, not stash@{0}.
        if [[ "$STASHED" == "yes" ]]; then
          OUR_STASH_REF=$(find_our_stash_ref "$STASH_MSG") || OUR_STASH_REF=""
          if [[ -z "$OUR_STASH_REF" ]]; then
            MERGE_SHA=$(git -C "$ROOT" rev-parse HEAD)
            STUCK_FILE="$STATE_DIR/STUCK-${TS}-${SLUG}.md"
            cat >"$STUCK_FILE" <<EOF
# Stuck — autostash entry missing

The task-queue runner merged \`$BRANCH\` into \`main\` but could not locate its autostash entry to restore your WIP. The entry should have been "$STASH_MSG" — search \`git stash list\` to find it (or check whether another process popped it).

- Task merge commit: \`$MERGE_SHA\`
- Task: \`$SLUG_BASE\`
- Expected stash message: \`$STASH_MSG\`
- Run log: \`$LOG_FILE\`
EOF
            echo "[task-queue] autostash entry not found — possible race with another runner; halting"
            echo "[task-queue] details: $STUCK_FILE"
            cleanup_worktree "$WORKTREE" "$BRANCH"
            release_main_lock
            flock -u 9; exec 9>&-
            exit 1
          fi
          if ! git -C "$ROOT" stash pop "$OUR_STASH_REF" >>"$LOG_FILE" 2>&1; then
            STASH_REF="$OUR_STASH_REF"
            MERGE_SHA=$(git -C "$ROOT" rev-parse HEAD)
            # Write STUCK.md to the state dir (NOT the worktree) because
            # we're about to remove the worktree on the cleanup line below.
            # Timestamped name preserves history across multiple incidents.
            STUCK_FILE="$STATE_DIR/STUCK-${TS}-${SLUG}.md"
            cat >"$STUCK_FILE" <<EOF
# Stuck — autostash pop conflict

The task-queue runner merged \`$BRANCH\` into \`main\` successfully, but restoring your stashed WIP via \`git stash pop\` conflicted with the merged changes. The merge commit landed; your WIP is preserved in the stash.

- Task merge commit: \`$MERGE_SHA\`
- Task: \`$SLUG_BASE\`
- Stash entry: \`$STASH_REF\` ("$STASH_MSG")
- Run log: \`$LOG_FILE\`

To resolve:
1. \`cd $ROOT && git status\` — see conflict markers from the partial stash apply
2. Resolve conflicts manually, then \`git add\` the resolved files
3. (No commit needed — stash apply leaves the changes uncommitted, matching the pre-stash state.)
4. \`git stash drop $STASH_REF\` once you're satisfied
5. \`rm $STUCK_FILE\` once you're done

The task branch and worktree have been removed (merge already landed on main).
EOF
            echo "[task-queue] autostash pop conflicted — main is merged but your WIP is in $STASH_REF; halting"
            echo "[task-queue] details: $STUCK_FILE"
            cleanup_worktree "$WORKTREE" "$BRANCH"
            release_main_lock
            flock -u 9; exec 9>&-
            exit 1
          fi
          echo "[task-queue] restored main's WIP from autostash"
        fi

        echo "[task-queue] merged; removing worktree and branch"
        cleanup_worktree "$WORKTREE" "$BRANCH"
        release_main_lock
        # Retire the daemon's session registry entry so the worker stops
        # appearing in `claude agents` / Claude mobile app / claude.ai/code.
        # Without this, state=done sessions persist indefinitely and the
        # user's session list accumulates clutter across iterations.
        # Idempotent on already-stopped/done sessions.
        claude stop "$SHORT_ID" >/dev/null 2>&1 || true
        printf '%s success: merged %s\n' "$(date -Iseconds)" "$BRANCH" >> "$LOG_FILE"

      elif [[ $ADVANCED -eq 0 && -z "$DIRTY" ]]; then
        # Worker exited clean without committing anything. This is the
        # "empty queue" case (worker saw nothing to do) OR a worker that
        # decided to bail without leaving WIP. Either way, no merge is
        # needed and the queue file is intact on main. Tear down so the
        # next iteration starts fresh.
        echo "[task-queue] worker exited without committing — discarding worktree"
        cleanup_worktree "$WORKTREE" "$BRANCH"
        claude stop "$SHORT_ID" >/dev/null 2>&1 || true
        printf '%s no-progress: %s\n' "$(date -Iseconds)" "$BRANCH" >> "$LOG_FILE"

      else
        # Worker exited with uncommitted edits in the worktree. We don't
        # auto-commit those — could be partial work, could be a bug.
        # Mark the queue file so the same task doesn't immediately
        # re-spawn, and leave the worktree for inspection.
        echo "[task-queue] worker left uncommitted edits — marking abandoned-wip"
        mark_queue_file "$TASK_FILE" "abandoned-wip" "$TS"
        cat >"$WORKTREE/STUCK.md" <<EOF
# Abandoned with uncommitted edits

Worker exited cleanly but left uncommitted edits in this worktree.

- Runner's read: \`${WORKTREE_BUSY_REASON:-uncommitted edits left behind after the worker exited}\`
- Worktree: \`$WORKTREE\`
- Branch:   \`$BRANCH\`
- Original queue file: \`$TASK_REL_PATH\` (renamed on main with a \`.abandoned-wip.$TS.md\` suffix)
- Run log: \`$LOG_FILE\`

Inspect \`git status\` and \`git diff\` in this worktree to decide whether to keep the WIP. To re-queue the task as-is, rename the \`.abandoned-wip.$TS.md\` file back to its original name and \`git worktree remove\` this directory.
EOF
        printf '%s abandoned-wip: %s\n' "$(date -Iseconds)" "$BRANCH" >> "$LOG_FILE"
      fi
      ;;
    *)
      # Genuine crash (124 = timeout fired; anything else = claude died
      # unexpectedly or was killed externally). Mark the queue file and
      # keep the worktree for forensics.
      echo "[task-queue] crash (exit $EXIT_CODE) — marking crashed and keeping worktree"
      mark_queue_file "$TASK_FILE" "crashed" "$TS"
      cat >"$WORKTREE/STUCK.md" <<EOF
# Crashed

Worker exited with code $EXIT_CODE (124 = timeout fired; anything else = claude died unexpectedly).

- Worktree: \`$WORKTREE\`
- Branch:   \`$BRANCH\`
- Original queue file: \`$TASK_REL_PATH\` (renamed on main with a \`.crashed.$TS.md\` suffix)
- Run log: \`$LOG_FILE\`

Inspect the worktree and the session JSONL transcript in \`~/.claude/projects/<project-hash>/\` to understand what happened. To re-queue: rename the \`.crashed.$TS.md\` file back to its original name and \`git worktree remove\` this directory.
EOF
      printf '%s crashed: %s\n' "$(date -Iseconds)" "$BRANCH" >> "$LOG_FILE"
      ;;
  esac

  flock -u 9
  exec 9>&-
done
