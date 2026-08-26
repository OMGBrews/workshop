---
name: task-status
description: Read-only status report on this repo's tasks — one task in depth when given a task file, otherwise a brief sweep of the whole queue. Detects finished-but-not-closed work, premature or stale in-progress markers, bucket/status contradictions, rotted briefs, and runner execution state in queue repos. Reports what code, docs, and git history actually say; never edits anything.
---

# Task status

Answer one question: **what is the actual status of this task — or, with no
argument, of every task in this repo?** Consult the task file, the code and
documentation it names, the git history, and anything else relevant before
delivering your report. You decide what is important to report; there is no
template. Given a task file (`task-status <task-file>`), go deep on that one.
Given none, sweep the tasks root — `docs/work/tasks/` — buckets
`finalized/ now/ soon/ later/ never/`, plus `queued/` where the autonomous runner
is in use — and keep each verdict brief. Scope is this repo only; sibling
clones in a workspace checkout are out of scope.

**Strictly read-only.** Report; never edit, delete, or move anything. Route
follow-ups to the skill that owns them: the `task-implement` skill closes finished work
out (completed tasks are deleted, not marked done), the `task-audit` skill re-verifies a
brief in depth, `task-finalize` owns admission to `finalized/`, and
`task-reprioritize` / `task-move` own the remaining bucket placement.

## Known traps in this fleet — each has produced a wrong report before

- **`[~]` markers exist.** A checked-vs-total count that only sees `[ ]` and
  `[x]` reads a partially-done task as finished. Count inside the
  `AC:BEGIN`/`AC:END` sentinels only (checkbox lists appear in other sections
  too); anything that is not `[x]` is not done.
- **`git log -1` dates the last sweep, not the last work.** Bulk migrations
  have touched every task file at once; skip wide bookkeeping commits when
  dating a task's real activity.
- **A rot check on an untracked path silently passes.** `git log <sha>..HEAD
  -- <path>` prints nothing and exits 0 for a gitignored or sibling-clone path
  (hq tasks naming `devtools/` paths are the live case). Verify the path is
  tracked (`git ls-files --error-unmatch`) before calling its diff clean.
- **`grep` may honor `.gitignore`** (it is ugrep in some environments), so a
  recursive search can return a silently incomplete result. Pass explicit
  paths.
- **Unknown is a verdict, not zero.** No parseable ACs is "AC state unknown",
  not 0/0; no `finalized-at` stamp is "never verified", not "no rot"; an
  unreachable stamp is "rot unknown", not a clean diff.
- **(Queue repos) a lock file proves nothing about liveness.** A crashed
  runner leaves its lock behind; only failing to acquire the flock proves a
  holder is alive (`runner_alive_for_slug` in `task-queue/run.sh`). Report
  liveness unknown where `flock` is unavailable. Forensic markers
  (`.crashed`, `.merge-failed`, …) on files in `queued/` are tasks the runner
  will never retry — always worth reporting.
