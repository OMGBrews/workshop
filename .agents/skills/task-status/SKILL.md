---
name: task-status
description: Read-only status report on this repo's tasks — one task in depth when given a task file, otherwise a brief sweep of the whole queue. Detects finished-but-not-closed work, premature or stale in-progress markers, bucket/status contradictions, rotted briefs. Reports what code, docs, and git history actually say; never edits anything.
---

# Task status

Answer one question: **what is the actual status of this task — or, with no
argument, of every task in this repo?** Consult the task file, the code and
documentation it names, the git history, and anything else relevant before
delivering your report. You decide what is important to report; there is no
template. Given a task file (`task-status <task-file>`), go deep on that one.
Given none, sweep the tasks root — `docs/work/tasks/` — buckets
`finalized/ now/ soon/ later/ parked/`, plus any legacy `queued/` briefs awaiting recovery — and keep each verdict brief. Scope is this repo only; sibling
clones in a workspace checkout are out of scope.

**Strictly read-only.** Report; never edit, delete, or move anything. Route
follow-ups to the skill that owns them: the `task-implement` skill closes finished work
out (completed tasks are deleted, not marked done), the `task-audit` skill re-verifies a
brief in depth, `task-finalize` owns admission to `finalized/`, and
`task-reprioritize` / `task-move` own the remaining bucket placement.

## Parked briefs

For every brief in `parked/`, inspect the parking note using the
[canonical bucket definitions](../task-create/bucket-definitions.md), resolved
relative to this skill's physical directory:

- Report a missing, misplaced, duplicated, or incomplete `## Parked` section.
  It belongs immediately after `**In brief**:` and must contain substantive
  `**Why**:` and `**Unpark when**:` entries. Empty text, HTML comments, and
  placeholders such as `<reason>`, `TODO`, or `TBD` do not count. Report
  `status: in-progress` as a parked/status contradiction.
- Display the actual unpark condition and optional `unpark-after:` value.
  Compare valid `YYYY-MM-DD` calendar dates with today's date and state the
  date used. Flag dates on or before today as due for review. Report malformed,
  repeated, or contradictory date metadata; do not guess which value governs.
  An absent date is allowed, and a date field never replaces the note.
- Evaluate dependency conditions against readily available git history or
  delivered-work evidence. Read the note's wording: one completed dependency
  does not satisfy a condition requiring several. A missing dependency slug
  alone is uncertainty, never completion; inspect history to distinguish
  completion from renaming, rejection, or a typo, and report unknown when the
  evidence cannot settle it. Cite the supporting commit or artifact for a
  condition that appears met.
- Leave code conditions that require investigation to `task-audit`; report
  them as unevaluated rather than claiming they are unmet. Recommend that
  audit or a deliberate `task-move` as appropriate. No report automatically
  unparks a task, including a rejected brief carrying `## Rejection rationale`.

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
  (hq tasks naming `workshop/` paths are the live case). Verify the path is
  tracked (`git ls-files --error-unmatch`) before calling its diff clean.
- **`grep` may honor `.gitignore`** (it is ugrep in some environments), so a
  recursive search can return a silently incomplete result. Pass explicit
  paths.
- **Unknown is a verdict, not zero.** No parseable ACs is "AC state unknown",
  not 0/0; no `finalized-at` stamp is "never verified", not "no rot"; an
  unreachable stamp is "rot unknown", not a clean diff.
- **Legacy queues are recovery work.** Autonomous execution is retired. Report
  surviving queued briefs, marker files, branches, or worktrees for inspection;
  their presence proves neither a live runner nor completed work.
