# task-queue skill

Autonomous task-queue loop runner. Watches the `queued/` bucket of the repo's
tasks directory — `docs/work/tasks/queued/`; written `<tasks>/queued/` below — and,
whenever the queue holds a claimable task no runner is already working —
dependencies merged, ordered by frontmatter priority — claims it, creates a
dedicated git worktree on a branch off
`main`, spawns a fresh `claude` inside that worktree to implement the task,
then merges the result back into `main` with `git merge --no-ff` and tears
down the worktree.

Run it in **N terminals at once** for parallel throughput — the runners
cooperate via per-task and main-mutation locks. See [Running multiple
runners in parallel](#running-multiple-runners-in-parallel).

This is the operator README for the `task-queue` skill. The skill is
self-contained — `SKILL.md` (the `/task-queue` quick-start), `run.sh` (the
loop runner), `initial-prompt.md` (the worker prompt), and this file all
live together in this directory.

These notes cover the runner specifically (operating, logs, sandboxing). The
public skill files in this directory carry the complete standalone workflow;
the private fleet procedure is deliberately not linked from Workshop.

## Quick start

```bash
bash .claude/skills/task-queue/run.sh
```

`bash run.sh` **auto-detaches**: it re-execs the runner under `setsid
script`, returns the terminal to you immediately, and prints the
detached runner's pid and runner-log path. The runner keeps going after
you close the terminal. Watch it with:

```bash
tail -f .task-queue/runner-<ts>.out
```

Pass `--foreground` to opt out — the runner then runs in the launching
terminal with live stdout, for debugging the runner itself.

## Root guard

The runner deliberately walks three levels from the path you typed without
resolving skill-directory symlinks. That makes the normal logical spellings
(`.agents/skills/task-queue` and `.claude/skills/task-queue`) select the
mounting project's queue rather than devtools' own tree. It accepts a plain
clone or linked worktree only when that resolved path is the Git worktree root
and has no superproject; a physical path inside a devtools submodule is
rejected before it can create queue state there.

Use a logical skill path from the project root, for example:

```bash
bash .agents/skills/task-queue/run.sh
bash .claude/skills/task-queue/run.sh
```

If the guard rejects a nested path or submodule, its error names the resolved
root and prints the corresponding invocation from the enclosing or mounting
repository. A non-Git path reports that no repository root could be found.

Drop task files into `<tasks>/queued/` and **commit them** —
the runner watches main's HEAD, not the working tree, so an
uncommitted file is invisible. Use `/task-move <task> queued` (which validates
readiness and stages the move for you to commit) or commit manually:

```bash
git add <tasks>/queued/<task>.md && git commit -m "task-queue: enqueue <task>"
```

The runner claims the first eligible task at HEAD that no sibling runner
already holds, on the next poll cycle — highest frontmatter `priority:`
first (alphabetical within a priority), skipping tasks whose
`dependencies:` haven't merged to `main`.

Stop it with `bash run.sh stop` — a graceful stop that asks **every**
parallel runner of this queue to exit at its next iteration boundary.
To stop one runner only, `kill -TERM <pid>` it (the pid printed at
launch). A second signal escalates to a fast stop. See [Stopping the
runner](#stopping-the-runner).

## Launching from a non-interactive context

No special wrapper is needed. `bash run.sh` already auto-detaches: it
re-execs itself under `setsid script` on every launch. `setsid` puts the
runner in a new session with no controlling terminal, so closing the
launching terminal can never SIGHUP it; `script` allocates a fresh pty,
which the `claude --bg` workers need for their Remote Control / Agent
View registration handshake. Runner stdout/stderr is captured to
`.task-queue/runner-<ts>.out`.

Because that is exactly what the old `nohup script -qec "bash run.sh"
…` wrapper used to provide, the wrapper is now obsolete. A plain

```bash
bash .claude/skills/task-queue/run.sh
```

works identically from a real terminal, from inside a Claude Code
session, from CI, or remotely over SSH — the launching command returns
immediately, prints the detached runner's pid and runner-log path, and
the runner survives the launcher exiting.

Stop it from anywhere with `bash run.sh stop` (no pid needed — it
gracefully stops every running runner of this queue). See [Stopping the
runner](#stopping-the-runner).

The same applies to `audit-queue` and any other runner that shares this
lifecycle.

## Files

All bundled in this skill directory:

| Path | Purpose |
|------|---------|
| `SKILL.md` | The `/task-queue` skill entrypoint — quick-start summary, discoverable in Claude Code. |
| `run.sh` | The loop. Polls, claims the first unlocked task, creates worktree, spawns `claude`, merges, cleans up. Handles crashes and merge conflicts. Safe to run in N parallel copies. |
| `initial-prompt.md` | The prompt every fresh worker receives. Tells it its task path, that it's in a private worktree, what to commit, how to self-terminate. Carries `<!-- include: execution-discipline.md#<anchor> -->` directives where the five shared discipline blocks sit; `render_worker_prompt` in `run.sh` splices them in at dispatch. The assembled prompt was byte-identical to the old fully-inline one from the 2026-08-01 split until 2026-08-18, when the `staleness-check` block gained the tracked-path guard in a deliberate re-baseline (rendered and diffed, the delta exactly the guard text). That identity is history, not an invariant: the blocks are live runner configuration, and the way to verify a change is still to render both sides and diff. **Never vendor this file without the matching `run.sh`** — a plain `cat` leaves the directives as literal comments and the worker loses its discipline silently. |
| `execution-discipline.md` | The five shared discipline blocks — staleness check, recommended-solution-is-advisory/ACs-are-contract, definition-of-done lookup, AC-sentinel editing rule, ask-with-briefing. Expanded into the worker prompt at dispatch and read directly, in-session, by `/task-implement`. Editing it changes what an unattended worker is told on its next run. |
| `self-terminate.sh` | The worker's self-termination script. Walks up the process tree to the worker's `claude` parent and sends it SIGTERM. The runner passes its absolute path to the worker via `TASK_QUEUE_SELF_TERMINATE`. |
| `test-run.sh` | Unit tests for the parallel-safety primitives — `claim_next_task` (lock-skipping pickup) and `acquire_main_lock` / `release_main_lock` — the lifecycle primitives — the signal-flag stop (`request_stop` / `should_stop`) and the reconcile liveness probe (`runner_alive_for_slug`) — the CI auto-fix primitives (slug extraction, fingerprint attempt counting, dispatch/skip/escalate/done disposition) — and completion detection: `check_stall_signature` over fabricated `state.json`/JSONL fixtures, `worker_quiet_seconds`, the `bg_episode_*` record driven by a scripted sequence of (armed, tempo) pairs, `worktree_busy`, and a mirror-identity assertion that diffs the eleven shared function bodies against `audit-queue/run.sh`. Run `bash test-run.sh`; ~1s, no git repo, daemon, or network needed. |
| `probe-completion-detection.sh` | Operator-invoked live proof of the background-work guard. Drives a real `claude --bg` session into the guarded state and asserts the runner's own `check_stall_signature` holds — and that a genuine stall is still declared once nothing is armed. Takes a runner argument. Not wired into any gate; see [Proving the background-work guard](#proving-the-background-work-guard). |
| `probe-persistent-inflight.sh` | Operator-invoked live proof of the **bound** on that guard, and the complement of the probe above: drives a real session into the state where the count never drains (a persistent Monitor), then asserts the guard holds below `STALL_BG_MAX_S` and lets go past it — with the count still armed — and that the `claude stop` this authorizes actually recovers the session. Takes a runner argument. Not wired into any gate; see [Proving the suppression bound](#proving-the-suppression-bound). |
| `README.md` | This file — operator notes. |

## Design

- **Worktree per task.** Each task runs in `.task-queue/worktrees/<slug>/` on
  branch `task-queue/<slug>`, branched off `main`. The main working tree
  stays clean throughout — you can work on other things in parallel without
  fighting dirty-state. Per-task lifecycle:

  ```
  claim first queued/<task>.md whose lock is free
    → flock .task-queue/locks/<slug>.lock      (held for the whole task)
    → git worktree add -b task-queue/<slug> .task-queue/worktrees/<slug> main
    → symlink .env, .venv, app/frontend/node_modules, data/ into worktree
    → spawn `claude` in worktree (TASK_QUEUE_TASK_PATH set to the brief)
    → worker implements, commits; closure commit repairs inbound doc
      links to the brief + git rm's it, then the worker ends its turn
    → runner: fallback git rm of the brief (only if the worker skipped
      its closure commit; cannot repair links semantically)
    → flock .task-queue/locks/main.lock         (serialize all main writes)
    →   runner: git stash push (on main, if dirty) — autostash
    →   runner: git update-index --refresh (on main; stat-cache defense)
    →   runner: git merge --no-ff task-queue/<slug> (on main)
    →   runner: git stash pop (if stashed)
    →   runner: git worktree remove + git branch -d
    → release main.lock
    → release <slug>.lock, loop
  ```

- **Parallel-safe by construction.** Two locks let N runners share one
  queue without corrupting `main`:
  - **Per-task lock** (`.task-queue/locks/<slug>.lock`, fd 9) — a runner
    `flock -n`s a task's lock to claim it and holds it for the whole
    task. `claim_next_task` walks the queue in eligibility order
    (priority, then alphabetical; dependency-blocked tasks excluded) and
    skips any task whose lock a sibling already holds, so each runner
    takes a different task. flock is advisory-per-process, so a crashed
    runner's claims release automatically — no stale-lock cleanup.
  - **Main-mutation lock** (`.task-queue/locks/main.lock`, fd 8) — every
    write to `main` (the autostash → `merge --no-ff` → stash-pop
    sequence, and every marker-rename commit) is serialized through one
    host-wide lock. Worker runs are fully parallel; only the few-seconds
    merge is mutually exclusive. The lock is re-entrant within a runner
    (a marker commit *inside* the already-locked merge block doesn't
    self-deadlock).

  `test-run.sh` unit-tests both. Caveat: parallel runners share the
  symlinked `data/` directory — see [Running multiple runners in
  parallel](#running-multiple-runners-in-parallel).

- **Fresh context per task.** Each iteration is a brand-new `claude`
  invocation — no `--continue`, no `--resume`. Context, memory, and instruction
  files load fresh.

- **Runner picks the task, not the worker.** Selection reads main's HEAD
  via `git ls-tree`, not the working tree — so the runner only sees tasks
  that have been *committed* to `queued/`. A staged-but-uncommitted
  `git mv` (or a freshly-written file that hasn't been committed yet)
  is invisible to the runner. This is intentional: the worker's worktree
  branches off main's HEAD, so anything not at HEAD wouldn't appear in
  the worker's filesystem anyway. Watching HEAD makes the race window
  impossible. The worker receives its assigned path via the
  `TASK_QUEUE_TASK_PATH` environment variable.

  Pickup order: frontmatter `priority:` (`high` → `medium` → `low`;
  absent defaults to `medium`), then alphabetical — deterministic. Tasks
  whose frontmatter `dependencies:` list a slug not yet merged to `main`
  are excluded until every dependency's brief has been queued and has
  left the queued/ tree cleanly (strict DAG). The ordering is race-free
  across parallel runners: each runner `flock`s a task's
  `.task-queue/locks/<slug>.lock` before taking it and walks past tasks
  a sibling already holds.

  Older runner versions had the worker pick from the queue itself; the
  prompt still falls back to that behavior when `TASK_QUEUE_TASK_PATH`
  is unset, so the prompt and script can be updated independently.

- **Auto-detaches on launch.** `bash run.sh` re-execs the runner under
  `setsid script` and returns the terminal immediately — the runner
  survives the terminal closing and captures its output to a runner log
  (`.task-queue/runner-<ts>.out`). The worker session itself is dispatched
  in the background via Agent View + Remote Control (see below), so
  clarifying questions are answered from claude.ai/code or the mobile
  app, not by typing into a terminal. Only `--foreground` runs the runner
  in the launching terminal.

- **Graceful and fast stop.** A stop request — `run.sh stop`'s global
  sentinel, or one `SIGINT`/`SIGTERM` to a runner — is *recorded*, not
  acted on immediately. The signal handler only sets a flag; the loop
  checks it at the iteration boundary and exits there, after the current
  iteration's merge and cleanup have finished. The runner never exits
  mid-merge or mid-`wait_for_bg_session`. A second signal escalates to a
  fast stop: the in-flight worker is `claude stop`ped instead of waited
  on, and the runner exits promptly. (The old handler did a bare
  `exit 0` from inside the handler, at whatever arbitrary point the
  signal interrupted — that is what orphaned in-flight branches; see the
  2026-05-22 kaizen entry.) See [Stopping the runner](#stopping-the-runner).

- **Reconcile on launch + crash recovery.** A runner killed violently
  (SIGKILL, OOM, container restart) between "worker committed" and
  "runner merged" leaves a complete task branch stranded. Every launch
  scans for such orphaned `task-queue/*` branches and *reports* them,
  pointing at `run.sh recover`. It never auto-merges on launch. See
  [Crash recovery](#crash-recovery).

- **Dispatched via Agent View + Remote Control.** Each session is launched
  with `--bg --name <task-slug> --remote-control "task-queue: <task-slug>"`.
  The two flags cover two independent surfaces. `--bg` registers the session
  with Claude Code's local Agent View supervisor (shipped 2026-05-11): the
  worker shows up in `claude agents` and its output is queryable via
  `claude logs <slug>`. `--remote-control` attaches Remote Control: the
  session appears at claude.ai/code and in the Claude mobile app, and its
  `AskUserQuestion` / `PushNotification` calls reach the phone. `--bg` alone
  does NOT do the second half — a bare-`--bg` worker reports "Mobile push
  not sent — Remote Control inactive" (see the 2026-05-22 kaizen entry).
  Requires Claude Code ≥ 2.1.139 and a claude.ai login (`claude auth login`).

- **Self-termination, not a kill-from-outside.** Interactive `claude` does
  not exit on its own when it stops responding — it sits at the TUI prompt.
  As its final action the worker runs `self-terminate.sh`, which walks up
  the process tree from its own shell to the nearest `claude` ancestor and
  sends it `SIGTERM`. This replaces the more common Stop-hook + sentinel-file
  dance, and is safe in a multi-Claude-Code sandbox because the process-tree
  walk is local to the session that runs it.

  The script is a **bundled file**, not inline prompt text, and the runner
  passes its absolute path to the worker via the `TASK_QUEUE_SELF_TERMINATE`
  env var (alongside `TASK_QUEUE_TASK_PATH` etc.). The prompt only tells the
  worker to run `bash "$TASK_QUEUE_SELF_TERMINATE"`. This is deliberate:
  self-termination is load-bearing — if it fails, the runner blocks until the
  task timeout — and a worker reaching for it deep in a long context can't be
  trusted to reproduce an 8-line script with anchored regexes and exact
  signal flags byte-for-byte. A file runs verbatim; an absolute path in an
  env var is also cwd-proof, where a relative path would break if the worker
  had `cd`'d elsewhere during the task. There is intentionally **no inline
  fallback** in the prompt — if `TASK_QUEUE_SELF_TERMINATE` is unset the
  runner is broken in a way the worker shouldn't paper over. If we ever
  observe the env-var path failing in practice, revisit adding belt-and-
  suspenders redundancy then.

- **All permissions bypassed.** The runner passes
  `--permission-mode bypassPermissions` so the autonomous session never
  prompts — for edits, Bash, MCP tools, or anything else. Required for
  hands-off operation. **Only safe in a sandboxed host environment** (dev
  container, VM, etc.). If you're running this on a bare workstation,
  change `run.sh` to `--permission-mode acceptEdits` (auto-accept edits
  only, prompt on the rest) or `default` (prompt on everything) and accept
  the interruptions.

- **Built-in `claude --worktree` flag is intentionally NOT used.** That
  flag is designed for interactive UX: it prompts at exit ("keep this
  worktree?") whenever a named session ends with changes, which would
  hang an unattended loop. The runner also needs to merge *before*
  any cleanup decision, so external worktree management is the right
  primitive here.

## Permission mode

The default is `bypassPermissions` — full auto-accept across every tool
class. This is the only mode that genuinely doesn't pester the user.
Override by editing `run.sh` directly — there is intentionally no env-var
knob, because the choice should be deliberate. Only switch back to
`acceptEdits` or `default` if you're running the loop outside a sandbox.

## Timeouts

**No per-task timeout by default.** The realistic operating mode is
phone-mediated dialog where a worker may legitimately wait hours on a
single `AskUserQuestion` call. A hard ceiling kills those legitimate
waits and marks otherwise-valid tasks as `.crashed.<ts>.md`.

Opt back in per-run when you want one — useful for CI or unattended
overnight runs where you accept losing slow tasks:

```bash
TASK_QUEUE_TIMEOUT=60m bash .claude/skills/task-queue/run.sh
TASK_QUEUE_TIMEOUT=2h bash .claude/skills/task-queue/run.sh
```

When the timeout fires, `claude` receives `SIGTERM` and the loop treats
it as a crash (see "Exit handling" below).

Stuck workers (no timeout set, worker genuinely hung): signal the
runner twice for a fast stop (the in-flight worker is `claude stop`ped,
the runner exits) — see [Stopping the runner](#stopping-the-runner).
The task branch and worktree are preserved for forensics.

### Declining a question to chat

The runner normally treats "worker ended its turn" (`state=blocked
tempo=blocked`) as completion and takes over. But when you **decline**
an `AskUserQuestion` to chat in free text instead of picking an option,
the worker drops to a plain-text question ("what would you like to
clarify?") and ends its turn — which looks identical to completion. The
runner detects this decline-to-clarify case (`worker_in_clarification_dialog`)
and holds the session open so you can type your reply. Each message you
send resets the window; if you go quiet for `CLARIFY_GRACE_S` (default
600s) the runner concludes the dialog is over and closes the iteration
out. Override the window with `TASK_QUEUE_CLARIFY_GRACE_S`.

### Workers waiting on backgrounded commands

A worker that backgrounds a long command — which the worker prompt
*requires* for commits, since the pre-commit gate outruns tool timeouts —
gets an instant "running in background" acknowledgement, ends its turn to
await the completion notification, and then goes quiet. Quiet is what a
healthy worker looks like here, and the runner used to read it as a
finished one: on 2026-07-31 it `claude stop`ped a worker mid-commit and
staged a `git rm` of the brief into the worktree that was still
committing.

The runner now consults the daemon's own `inFlight.tasks` counter
(`~/.claude/jobs/<id>/state.json`) before concluding anything from
silence. While that count is above zero the worker is left alone — up to
a bound, because the count does not always drain. Three
operator-visible consequences:

- `worker's turn ended with background work still in flight — holding
  takeover` means the runner is waiting on a real backgrounded command,
  not hanging. The hold is capped at `TASK_QUEUE_BG_HOLD_MAX_S` (default
  900s) because the counter has been observed to leak; on expiry the
  runner logs `background-work hold exceeded …` and proceeds.
- `quiet …s with inFlight.tasks=… still armed — past STALL_BG_MAX_S`
  (on stderr) means the *other* ceiling fired: the worker sat at
  `state=working` producing nothing for `TASK_QUEUE_STALL_BG_MAX_S`
  (default 1800s) while the daemon went on reporting work armed, so the
  runner stopped believing the count and took over. It prints alongside
  the ordinary `stall: …` takeover line, and the pair is what tells you
  a stuck counter from a stuck model. See [Why the suppression is
  bounded](#why-the-suppression-is-bounded).
- `note: daemon state.json exposes no numeric inFlight.tasks` (once per
  runner, on stderr) means a Claude Code release changed or dropped the
  field. The guard fails safe — it stops taking over stalled workers
  rather than risk killing healthy ones — so genuinely hung workers will
  need a manual fast stop until the field is restored or the runner is
  taught the new one.

`worktree_busy` backstops the same race at teardown: the runner refuses to
remove the brief from a worktree holding uncommitted tracked changes or an
in-progress git operation, marking the task `.abandoned-wip` and keeping
the worktree instead of racing whatever is still writing.

#### Why the suppression is bounded

`inFlight` counts more than backgrounded Bash. A **persistent Monitor**
stays armed for the worker's whole session, so `inFlight.tasks > 0` stops
being a transient condition and becomes a property of the session —
measured 2026-07-31 on Claude Code 2.1.220, `{"tasks":1,"kinds":
["monitor"]}` held across 281s of unbroken quiet with no sign of draining.

What makes that dangerous is where such a worker parks when it hangs:
`state=working`, `tempo=idle`. There, `check_stall_signature` is the
**only** recovery path the runner has. `wait_for_bg_session`'s
`done`/`failed`/`stopped` branches never fire — the daemon does not move a
hung session to a terminal state — its `state=blocked` branch, and
`BG_HOLD_MAX_S` with it, is never reached, and `TASK_QUEUE_TIMEOUT` is
empty by default. An unbounded suppression therefore waits on that worker
forever and the queue stops behind it.

So the suppression expires. Past `TASK_QUEUE_STALL_BG_MAX_S` (default
1800s) of unbroken quiet the count stops excusing the silence and the
stall is declared. The bound is anchored on worker **activity**, not on
when the count went positive: it is compared against the same
`worker_quiet_seconds` measurement the ordinary stall path uses, so any
real work the worker does resets it and only genuine silence accumulates.
30 minutes is ~3× the observed >10-minute cold-cache pre-commit gate, and
generosity is the right error side — crossing this bound stops a worker
that may be alive, which is the 2026-07-31 incident again, while the only
alternative on the other side is waiting forever.

The two ceilings stay **separate knobs on purpose**. `BG_HOLD_MAX_S`
bounds the `state=blocked` hold, measured from when that hold started;
`STALL_BG_MAX_S` bounds the stall suppression, measured from the worker's
last activity. Different questions, different anchors, tuned
independently.

The `kinds` field is *not* read, here or anywhere else in either runner.
The bound is on the count alone, so a worker is never treated differently
for the kind of work it happened to arm.

#### The episode record

Each stretch of in-flight background work leaves a **two-line record**
in the runner log — one line when the daemon's count first goes above
zero, one when the stretch ends:

```
[task-queue] 0f3a91c: background work in flight (inFlight.tasks=1) — takeover held until it drains
[task-queue] 0f3a91c: background-work episode ended after 95s — 19 polls, 17 at tempo=idle (where the inFlight gate is the only thing holding takeover off); the daemon's count drained to 0
```

The pair is emitted once per stretch, never per poll, and a run that
never enters the state produces no record at all.

**Read the `at tempo=idle` number, not the poll count.** Polls at
`tempo=active` are already covered by `check_stall_signature`'s first
gate (`[[ "$tempo" != "idle" ]] && return 1`), which predates the
`inFlight` guard entirely; only at `tempo=idle` is the `inFlight` check
the thing holding takeover off. An episode with **0 idle polls proves
nothing about that gate** — and that is exactly the shape of the
2026-07-31 run described under [Proving the background-work
guard](#proving-the-background-work-guard).

The trailing qualifier says how the stretch ended. `the daemon's count
drained to 0` is the healthy close. The variants ending `…with the count
still above 0` — the runner stopped waiting at `state=done`/`failed`/
`stopped`, took over at `state=blocked`, declared a stall, or hit the
per-task timeout — are the diagnostic ones: they are how a **leaked**
`inFlight` counter surfaces as an episode that never drained, instead of
as silence.

One operational caveat: a running runner keeps executing the `run.sh` it
started with, off its open file descriptor, even after a merge rewrites
that file on disk. The episode record will not appear in a live runner's
log until that runner is restarted.

## Proving the background-work guard

**A clean end-to-end task run is not, by itself, evidence that the guard
works.** The guard is silent when it does its job, so a green run is
equally consistent with the guard holding, with the guard never being
reached, and with the guard not being there at all.

That is not hypothetical. The first real queued-task run after the fix
(2026-07-31) passed cleanly — no markers, no manual recovery — and
proved nothing. A state sampler running alongside it recorded **255 of
258 polls at `tempo=active`**, and `check_stall_signature`'s *first*
gate is

```bash
[[ "$tempo" != "idle" ]] && return 1
```

which predates the fix, so the new `inFlight` check was never reached.
The worker also self-terminated, so `wait_for_bg_session` returned
through its `done` branch and the blocked-branch hold never ran either.

Whether a given run reaches the guarded state depends on how the worker
chooses to await its backgrounded commands: a polling loop (`until grep
-qE 'EXIT=' …; do sleep 5; done`) keeps the turn alive at
`tempo=active`, while ending the turn to await the completion
notification drops the session to `tempo=idle`. Both styles are
legitimate, both occur, and nothing specifies which — so "queue another
task and watch" is a coin flip.

### Running the probe

`probe-completion-detection.sh` removes the coin flip. It sources the
named runner's `run.sh` (the source-guard stops before the polling loop,
so nothing is dispatched and no task is claimed), spawns a cheap real
`claude --bg` session that runs one backgrounded `sleep 90` and is
instructed to **end its turn**, then polls every 5s calling that
runner's own `check_stall_signature`, `worker_bg_task_count`, and
`worker_quiet_seconds` against the live session.

```bash
bash .claude/skills/task-queue/probe-completion-detection.sh              # task-queue (default)
bash .claude/skills/task-queue/probe-completion-detection.sh audit-queue
bash .claude/skills/task-queue/probe-completion-detection.sh /path/to/run.sh
```

It needs no queued task, no merge to `main`, and no worker on the
default model. It takes about four minutes and a few cents, and
`claude stop`s the session it spawned on every exit path — including
Ctrl-C and an assertion failure.

Environment overrides: `PROBE_MODEL` (default `sonnet`), `PROBE_SLEEP_S`
(90), `PROBE_POLL_S` (5), `PROBE_PHASE1_MAX_S` (300),
`PROBE_PHASE2_MAX_S` (240).

### Reading the verdict

The probe prints a per-sample trace, then an "observed window" summary
(samples with work armed, samples that reached the guarded state,
longest quiet stretch while armed, violations, whether the complement
was observed) and one `PASS:`/`FAIL:` line per assertion. Exit codes:
**0** = guard proven, **1** = an assertion failed, **2** = could not set
up (missing `claude`/`jq`, dispatch failed, no `state.json`).

- **Phase 1** asserts the guarded state was *genuinely reached* —
  `tempo=idle`, non-terminal state, `inFlight.tasks > 0`, quiet ≥
  `STALL_GRACE_S` (default 30s) — and that `check_stall_signature`
  returned not-a-stall in every such sample. **A run that never reaches
  that state exits non-zero.** A vacuous pass is treated as a failure;
  that substitution is the whole reason this script exists.
- **Phase 2** asserts the complement: once nothing is armed and the
  session has been quiet past grace, a stall *is* declared. Without it
  the probe would pass just as happily against a runner whose stall
  detection had been deleted outright.

The summary line to read first is `...that reached the guarded state`.
If it is 0, nothing below it means anything — that run verified nothing,
and the probe says so and exits 1.

**If phase 1 passes and only phase 2 fails**, read it as a probe
infrastructure miss before you read it as a guard defect. Phase 2 needs
the spawned session to stay *non-terminal* while it goes quiet, and the
daemon closes a session out as `state=done` within about five seconds of
a turn that ends with no text — terminal states being excluded from
stall detection by design. The probe's prompt asks the session to answer
each re-invocation with a single line of plain text precisely to keep
that window open; a model that ignores the instruction takes the window
with it. Re-run once before concluding anything. A phase-1 failure, by
contrast, is never ambiguous.

### Negative control

Confirm the probe is capable of failing by disarming the guard through
its own knob — a bound of 0 means the suppression expires before it ever
applies, which is behaviourally the pre-guard runner:

```bash
TASK_QUEUE_STALL_BG_MAX_S=0 bash .claude/skills/task-queue/probe-completion-detection.sh
```

Expected: phase 1 prints `VIOLATION` lines beneath the guarded samples
and the script exits 1.

The path form of the argument does the same thing by surgery, against a
deliberately broken copy, when you want the gate gone rather than
expired:

```bash
cp -r .claude/skills/task-queue /tmp/tq-broken
python3 - <<'PY'
import pathlib, re
p = pathlib.Path("/tmp/tq-broken/run.sh")
p.write_text(re.sub(r"  if \(\( bg_tasks > 0 \)\); then\n(?:.*\n)*?  fi\n", "",
                    p.read_text(), count=1))
PY
bash .claude/skills/task-queue/probe-completion-detection.sh /tmp/tq-broken/run.sh
```

(Before the bound landed this was a one-line `sed` deleting
`(( bg_tasks > 0 )) && return 1`. That line no longer exists — the
suppression is now a multi-line block — so the old recipe silently
matches nothing and the "broken" copy is not broken at all: a negative
control that quietly turns into a positive one.)

### What probing one runner does not cover

Probing `task-queue` does **not** validate `audit-queue`, and vice
versa. `test-run.sh`'s mirror-identity assertion covers the **shared
guard only** — the eleven function bodies the two runners carry
byte-identically. Everything downstream of those functions differs
between the runners and remains untested:

- **Teardown.** When a worker leaves uncommitted edits, task-queue marks
  the brief `.abandoned-wip.<ts>.md`, keeps the worktree, and **carries
  on to the next task**; audit-queue writes a `STUCK.md` and **halts the
  loop** for a human.
- **The blocked-branch takeover.** The probe calls
  `check_stall_signature` directly and never runs
  `wait_for_bg_session`, so neither runner's `state=blocked` hold, its
  `BG_HOLD_MAX_S` expiry, nor what each runner then does is exercised.

Byte-identity is a strong guarantee about the functions it names and no
guarantee at all about the code around them. It is not, however, all
audit-queue has: both probes accept `audit-queue` and run against that
runner for real, so the shared guard can be exercised live on either
side. Run them there too — the byte-identity assertion is what makes a
`task-queue` probe *relevant* to audit-queue, not a substitute for
pointing a probe at it.

## Proving the suppression bound

The same problem one level down. The bound described under [Why the
suppression is bounded](#why-the-suppression-is-bounded) is silent until
it fires, and `test-run.sh` drives it over **fabricated** `state.json`
and JSONL fixtures — our own transcription of the daemon's shape. Those
unit tests are what catch a regression in the logic; what they cannot
tell you is that a real persistent Monitor still parks a real session in
the state the bound exists for.

`probe-persistent-inflight.sh` is the live half, and the complement of
`probe-completion-detection.sh`: that one proves the guard **holds** for
a worker legitimately awaiting a backgrounded command, this one proves
it eventually **lets go** of a worker whose count never drains.

```bash
bash .claude/skills/task-queue/probe-persistent-inflight.sh              # task-queue (default)
bash .claude/skills/task-queue/probe-persistent-inflight.sh audit-queue
bash .claude/skills/task-queue/probe-persistent-inflight.sh /path/to/run.sh
```

The `audit-queue` argument works the same way here: the sibling runner's
bound lives in the same byte-identical `check_stall_signature`, and
pointing this probe at it proves that copy holds and lets go against a
live daemon rather than inferring it from the mirror-identity assertion
and the unit tests.

It sources the named runner, then spawns a cheap real `claude --bg`
session that arms one **persistent** Monitor on a command printing
nothing and never exiting, and is instructed to end its turn. Both
details are load-bearing: a non-persistent Monitor expires and the count
drains to an ordinary unarmed stall, and a chatty one re-invokes the
session on every line it emits, resetting the quiet clock the bound
measures. The bound itself is lowered to `PROBE_BG_MAX_S` (default 120s)
for the run, so this takes about three minutes rather than half an hour.

Four assertions, in the order they are reported:

1. **The premise.** The daemon really does hold the count above zero for
   a persistent Monitor. If it drains instead, the hole this bound
   closes does not exist on that Claude Code build — the probe says so
   first and treats everything under it as meaningless.
2. **Below the bound the guard holds.** No takeover while quiet is under
   the bound with work armed.
3. **Past the bound it lets go**, with the count *still armed*, and says
   so on stderr in wording an operator can tell from an ordinary stall.
4. **The takeover recovers the session.** Declaring a stall is only a
   decision; `claude stop` is what the runner does with it, and a
   Monitor-armed session is exactly the shape that might not stop
   cleanly — so the probe issues the stop and waits for a terminal
   state rather than assuming one.

Exit codes match the sibling probe: **0** = bound proven, **1** = an
assertion failed, **2** = could not set up. Environment overrides:
`PROBE_BG_MAX_S` (120), `PROBE_MODEL` (`sonnet`), `PROBE_POLL_S` (5),
`PROBE_WATCH_MAX_S` (420), `PROBE_STOP_MAX_S` (60).

### Negative control for the bound

Point the probe at a copy of the runner with the bound removed — the
pre-fix shape — and confirm it fails:

```bash
cp -r .claude/skills/task-queue /tmp/tq-unbounded
# collapse the bounded block back to the unconditional suppression
python3 - <<'PY'
import pathlib, re
p = pathlib.Path("/tmp/tq-unbounded/run.sh")
s = p.read_text()
s = re.sub(r"  if \(\( bg_tasks > 0 \)\); then\n(?:.*\n)*?  fi\n",
           "  (( bg_tasks > 0 )) && return 1\n", s, count=1)
p.write_text(s)
PY
bash .claude/skills/task-queue/probe-persistent-inflight.sh /tmp/tq-unbounded/run.sh
```

Expected: `past the bound and still suppressed — the runner is waiting
forever` beneath the samples, then a `FAIL:` on assertion 3 and exit 1.

`PROBE_BG_MAX_S=9999 bash …/probe-persistent-inflight.sh` is a
zero-setup approximation — an unreachable bound behaves like no bound
within the watch window — but it exercises the probe, not the runner.
Use the copy when you want to know the *runner* is what is being tested.

## Stopping the runner

The runner detaches at launch, so there is no terminal to `Ctrl+C`.
Stop it one of two ways:

```bash
bash .claude/skills/task-queue/run.sh stop   # graceful — every runner
kill -TERM <pid>                             # graceful — one runner
```

- **`run.sh stop`** touches the global stop sentinel
  (`.task-queue/stop`). Every parallel runner of this queue observes it
  at its next iteration boundary and exits cleanly. It needs no pid and
  works from any terminal. A fresh launch clears a stale sentinel; a
  runner that is itself stopping leaves it in place so sibling runners
  still draining also see it.
- **One `SIGINT`/`SIGTERM`** to a single runner's pid (printed at
  launch) gracefully stops just that runner. `Ctrl+C` does the same, but
  only in `--foreground` mode — it is a `SIGINT` to the foreground
  runner.

A **graceful** stop means the runner *finishes the current iteration*
before exiting: if a worker is in flight, the runner waits for it,
merges its branch into `main`, and cleans up — then exits at the
iteration boundary. It never exits mid-merge or mid-`wait_for_bg_session`.
If the runner is idle (polling an empty queue), it exits at the next
poll.

A **second** `SIGINT`/`SIGTERM` to a runner escalates to a **fast
stop**: the in-flight worker is `claude stop`ped (not waited on) and the
runner exits promptly. Use it to abandon a stuck or unwanted in-flight
worker without waiting hours.

## Crash recovery

A graceful stop and the supervised exit paths cover clean shutdowns. A
*violent* kill — `SIGKILL`, OOM, container restart — between the worker
committing and the runner merging is different: it leaves a complete
`task-queue/<slug>` branch stranded, ahead of `main`, with the task
file still mislabelled as untouched on `main`. This was the 2026-05-22
silent-orphan failure.

The runner closes it with **reconcile on launch**:

- On **every** launch, the runner scans for orphaned branches before
  taking new work. An orphan is any `task-queue/*` branch with commits
  ahead of `main` whose per-slug claim lock is **free**. A live runner
  holds its slug's advisory `flock` for the whole task; an advisory
  flock is released by the kernel the instant its holder dies, so a lock
  that can be re-acquired has no live runner behind it. This liveness
  probe is exact — no false positives against live sibling/parallel
  runners.
- The runner **reports** each orphan it finds (prints it to the runner
  log) and points at `run.sh recover`. It never silently ignores an
  orphan, never auto-merges on launch, never halts.

Recovery is a deliberate, explicit operator action:

```bash
bash .claude/skills/task-queue/run.sh recover
```

`run.sh recover` merges each orphaned branch into `main` — the same
autostash → `merge --no-ff` → stash-pop dance the success path uses,
under the host-wide main lock — and removes its worktree, branch, and
claim lock. A conflicting orphan is left intact for a human to resolve.
Recovery is never an automatic silent merge — that is precisely the
behaviour the lifecycle is designed to avoid.

## Exit handling

After each spawned `claude` exits, the runner classifies the result by exit
code AND worktree state, then takes one of five actions:

"Dirty" means **tracked** files in the worktree differ from HEAD — i.e.
`git diff --quiet HEAD` returns non-zero. Untracked files (the symlinks
the runner sets up, pytest's `__pycache__`, build artifacts) do NOT count
as dirty. The worker's commits are what matter.

| Worker exit | Worktree state | Runner action |
|---|---|---|
| 0 or 143 (clean self-term) | new commits, no tracked-file diff vs HEAD | Autostash main's WIP (if dirty), `git merge --no-ff` task branch into main, pop autostash, remove worktree, delete branch. **Success path.** |
| 0 or 143 | no new commits, no tracked diff | Discard worktree + branch silently. Queue file untouched (next iteration retries). |
| 0 or 143 | tracked-file diff vs HEAD present | Commit a rename of the queue file to `<task>.abandoned-wip.<ts>.md` on main. **Keep worktree** with `STUCK.md` explaining the state. Human inspects. |
| 0 or 143 (clean, commits present) | `validate_worker_state` disagrees with the success signal: brief still on disk, `pytest --collect-only` fails, or leftover `STUCK.md` | Commit a rename to `<task>.partial.<ts>.md` on main. **Keep worktree** with `STUCK.md` naming the failed check; nothing merges. Human inspects. |
| 130 (Ctrl-C) | any | Leave worktree, branch, lock, and queue file alone. Exit the runner cleanly. Re-running picks up where it left off. |
| Anything else (124 timeout, crash, external kill) | any | Commit a rename of the queue file to `<task>.crashed.<ts>.md` on main. **Keep worktree** with `STUCK.md`. Human inspects. |

**Merge flow (autostash → merge --no-ff → pop):** The whole sequence
runs while holding the main-mutation lock (`.task-queue/locks/main.lock`),
so a sibling runner's merge cannot interleave with this one's autostash
dance. Before the merge, the runner calls `git stash push` to save any
dirty WIP on main (no-op if clean). Then `git merge --no-ff` runs against
the autostashed clean state. On success, `git stash pop` restores the
WIP. The lock is released on every exit path — success, merge conflict,
and the autostash STUCK paths alike.

If `git merge --no-ff` fails (real conflict between task branch and
main's new commits), the runner captures the conflicting paths **before**
aborting — `git merge --abort` clears the unmerged index entries, and a
capture taken afterwards returns an empty list that reads exactly like
"no conflicts" — then aborts the merge, pops the autostash to restore the
WIP, commits a `.merge-failed.<ts>.md` stub marker in place of the queue
file, writes `STUCK-<ts>-<slug>-merge-failed.md` under `.task-queue/`,
and keeps the worktree.

The record goes to `.task-queue/`, **not** into the worktree, because its
own recovery steps tell you to `git worktree remove` — which used to
delete the document you were still reading, one step before its last. The
record leads with the conflicting paths and treats the cause as a
hypothesis conditioned on them: a merge failure confined to `queued/` is a
bookkeeping collision, not the code conflict the old text always asserted.

Note that `merge-failed` is the one label that does **not** rename the
queue file. It removes it and commits a deliberately dissimilar stub, so a
re-merge on retry is a clean both-sides-delete rather than a rename
collision. Every other label keeps the content-preserving rename, which is
what lets a human rename it back to `.md` to re-queue.

If `git stash pop` conflicts after a successful merge (your WIP and
the merged result both touched the same lines), the merge has already
landed on main and your WIP stays at `stash@{0}`. STUCK.md names the
stash ref for surgical recovery, and the runner halts (rather than
continuing — otherwise the next task would pile another stash on top).

**Why `merge --no-ff` instead of rebase + ff-merge?** On this
devcontainer's overlay filesystem, `git rebase` (both default merge
backend AND `--apply`) spuriously aborts mid-replay with "Your local
changes would be overwritten" on provably-clean worktrees. The bug is
non-deterministic and hits a different commit each run, so retries
don't help. `git merge --no-ff` uses the `ort` merge engine directly
without rebase's rewind+replay state, sidestepping the bug.

**Why autostash?** `git merge --no-ff` refuses if ANY file in main's
WT has uncommitted changes AND the merge would touch it — including
files only "carried forward" from main with no task-branch
contribution. Without autostash, an unrelated dirty file on main
(especially one newly added by another agent during the task run)
would halt the loop. See kaizen entries 2026-05-14 and 2026-05-15.

Trade-off: main's history gets a merge commit per task instead of a
linear append.

The marker renames are **commits** on main, not working-tree renames.
This is necessary because the runner watches HEAD: a working-tree
rename would leave HEAD pointing at the original task path, and the
runner would re-pick it on the next poll. Each marker commit uses the
message format `task-queue: mark <task-name> as <marker>` so they're
easy to spot in `git log`.

Because the marker commit moves the brief off its original path, it
also stages a mechanical rewrite of any inbound markdown links
(old path → marker path) into the same commit, when the repo carries
`scripts/repair_doc_links.py` — otherwise a whole-tree doc-links gate
in the repo's commit hook refuses the marker commit itself, wedging the
runner on the very failure it is trying to record (the 2026-08-01
incident). The invocation is guarded on the script's existence, so
repos without such a gate (and without the script) get the plain
rename, links untouched.

The marker suffixes (`.crashed.`, `.abandoned-wip.`, `.merge-failed.`,
`.dispatch-failed.`, `.ci-stuck.`, `.partial.`) plus the `blocked/` subdirectory all
prevent the queue file from being re-picked. To re-queue, `git mv` the
marker file back to its original name and `git commit` (then also
`git worktree remove .task-queue/worktrees/<slug>` if a forensic
worktree was kept). `.ci-stuck` is the odd one out — it marks an
*autogenerated* CI follow-up whose failure kept recurring, so the
recovery is manual investigation, not a re-queue (see [CI auto-fix
loop](#ci-auto-fix-loop)).

## CI auto-fix loop

Between iterations of the pickup loop (and during idle polling — the
scan is time-gated internally, default every 120s), the runner closes
the post-merge CI blind spot:

1. **Poll.** `git log main --grep '^task-queue: merge '` lists recent
   merge commits; each sha without a recorded verdict is checked against
   `gh api repos/{owner}/{repo}/commits/<sha>/check-runs`. Unpushed
   commits and in-progress checks stay pending and are re-checked on
   later scans. A pushed commit with zero check runs resolves as
   "no-checks" after `TASK_QUEUE_CI_ZERO_CHECK_GRACE_S` (default 1h) —
   in a batched push only the tip gets check runs, and the tip's CI
   covers the batch cumulatively.
2. **Fingerprint.** On failure the runner pulls the first failed check
   run's job details (workflow, job, failed step, log tail centred on
   GitHub's `##[error]` markers) from the Actions API and pipes them to
   `format_ci_failure.py --emit fingerprint` (bundled in this skill
   directory) — an
   8-hex dedup key that survives run-to-run noise (timestamps, ANSI,
   shifted line numbers).
3. **Dispatch.** If the queue tree at HEAD carries no fix for that
   fingerprint, the runner commits
   `<tasks>/queued/fix-ci-<slug>-<fp8>.md` on `main` (under
   the main-mutation lock, same clean-index discipline as marker
   renames). The brief is generated by the same formatter (`--emit
   brief`): template-conformant, failure summary fenced and labelled as
   untrusted CI output, full-log fetch instructions included so the
   worker doesn't rediscover the failure via the lossy first-page API.
4. **Bounded retry.** `.task-queue/ci/fingerprints/<fp>.count` tracks
   dispatched follow-ups. At `TASK_QUEUE_CI_FIX_MAX_ATTEMPTS` (default
   2) a recurrence escalates: the brief is committed under a
   `.ci-stuck.<ts>.md` marker name (never picked up) and a
   `STUCK-<ts>-ci-<fp>.md` is written under `.task-queue/` with
   recovery steps. After escalation the loop is hands-off for that
   fingerprint; clear its files under `.task-queue/ci/fingerprints/`
   to re-arm.

Requires `gh` (authenticated), `jq`, `python3`, and an `origin` remote;
missing any, the scan disables itself with one log line. Disable
explicitly with `TASK_QUEUE_CI_SCAN_SECONDS=0`. Verdict state lives in
`.task-queue/ci/checked/` (one file per resolved sha — delete to force
a re-check).

This loop is **not** mirrored in `audit-queue/run.sh` — audit merges
don't gate on CI.

## Blocked tasks

A session that genuinely cannot proceed (decision needed from a human,
prerequisite unmet, missing context) will:

1. Append `## Blocked` to the task file explaining what stopped it.
2. `git add` + `git mv` the file to
   `<tasks>/queued/blocked/`.
3. Repoint any markdown links to the brief at its new `queued/blocked/`
   path, staged into the same commit (a whole-tree doc-links gate fails
   the move otherwise).
4. Commit and stop.

The runner treats this exactly like a successful run — it merges the move
into main and cleans up the worktree. `blocked/` is not rescanned. See
`<tasks>/queued/blocked/README.md` for how to re-queue.

## Logs

Per-iteration metadata logs (picked task, exit code, marker renames,
merge results) live in `.task-queue/logs/<timestamp>-<slug>.log`. These
are NOT full transcripts — Claude Code already writes a session JSONL to
`~/.claude/projects/<project-hash>/<session-id>.jsonl`. Use that for the
detailed conversation.

`.task-queue/` is gitignored, including `logs/`, `locks/`, and
`worktrees/`.

## Multi-Claude-sandbox safety

The runner is designed to coexist with other `claude` processes in the same
environment. Specifically:

- **No global hooks.** No entries in `~/.claude/settings.json`. The control
  flow is entirely in `run.sh`, the prompt text, and `self-terminate.sh`.
- **No shared sentinel files in `/tmp`.** Logs and locks live under
  `.task-queue/` (project-scoped).
- **Self-termination uses local process-tree walking.** `self-terminate.sh`
  walks up from the Bash tool's own shell to the nearest `claude` ancestor.
  By construction this can only be the session that ran the tool call —
  never a sibling Claude elsewhere in the sandbox.
- **Worktrees are namespaced under `task-queue/<slug>` branches.** Other
  Claude flows that create worktrees (e.g., manual worktree sessions
  under `.claude/worktrees/`) use different paths and branch names, so
  they won't collide.
- **Multiple task-queue runners coordinate via flock.** Running N copies
  of `run.sh` at once is safe and supported — see [Running multiple
  runners in parallel](#running-multiple-runners-in-parallel).

If you change any of those, re-check the assumptions: a global Stop hook in
particular would propagate to every Claude in the sandbox.

## Running multiple runners in parallel

Launch `run.sh` in **N separate terminals** and they cooperate
automatically — no `-N` flag, no coordinator process.
Each runner is an independent loop; the locks do the coordination:

- Task pickup is a non-blocking `flock` per task slug, so each runner
  claims a different task and walks past tasks a sibling already holds
  (`claim_next_task`). Work-stealing is automatic — a runner that
  finishes early grabs the next free task.
- Writes to `main` are serialized through one host-wide lock, so
  concurrent merges never corrupt the index (see **Design** above).

```bash
# three runners, three terminals — same command in each:
bash .claude/skills/task-queue/run.sh
```

`bash run.sh stop` gracefully stops **all** of them at once (one global
sentinel per queue). To stop just one, `kill -TERM` its pid; the others
keep running. Either way the stop is graceful — a runner with a worker
in flight finishes the current iteration first, merging that worker's
branch into `main` before exiting, so stopping mid-task no longer
orphans anything. (Stop on a queue lull only if you want the runners
down *immediately*; otherwise a graceful stop mid-task is safe.) See
[Stopping the runner](#stopping-the-runner).

### How many runners?

Bounded by host resources and your Claude plan, not by the runner
itself. Each worker is a full `claude` session that may also run the
app, evals, or pytest. On a dev container, 2–3 is a sensible ceiling;
all workers draw on the same Claude plan capacity, so beyond that more
runners hit rate limits rather than going faster.

### Caveats

- **Shared `data/` and `.venv`.** Every worktree symlinks the same
  `data/` directory (SQLite DB, vector store, LLM logs) and the same
  `.venv` from the main tree. Two workers that both run the app, run
  evals, or `uv pip install` can interfere. Most tasks touch neither, so
  this is usually fine — but if you're queueing several app/eval-heavy
  tasks, run them on a single runner or stagger them. Per-worktree
  `data/` isolation is the obvious next step if this bites.
- **More merge conflicts.** Each runner branches its task off `main` as
  it stood when that task started. Two in-flight tasks that touch the
  same files collide at merge time → `.merge-failed` (handled, but it
  needs a human). Queue disjoint tasks together and keep N modest.
- **audit-queue alongside.** Running `audit-queue` and `task-queue`
  together is safe for *pickup* (separate lock namespaces), but the
  audit-queue runner does not take task-queue's `main.lock` — so their
  merges into `main` are not serialized against each other. Two (or
  more) task-queue runners are fully safe; mixing in audit-queue is not
  yet — give audit-queue the same lock before relying on that combo.

## See also

- The repo's task-queue procedure doc, where one exists (e.g.
  `docs/procedures/development/task-queue.md`) —
  full end-to-end pipeline (`/task-create` → `/task-finalize` → `/task-move` →
  `queued/` → autonomous runner), including troubleshooting and known
  limitations.
- [`SKILL.md`](./SKILL.md) — the `/task-queue` skill entrypoint; discoverable
  quick-start summary.
- `<tasks>/queued/README.md` — what to put in the queue.
- `<tasks>/README.md` — overall task system.
