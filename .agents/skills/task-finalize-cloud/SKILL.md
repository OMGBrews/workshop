---
name: task-finalize-cloud
description: Send every task in one bucket of docs/work/tasks/ (now/ unless another bucket is named) to the cloud for finalization, one Claude Code on the web session per task, each running task-finalize on its brief and stopping at the orientation card for the owner to answer its open questions there. Reads the briefs from the default branch, skips tasks already being implemented or with a session or pull request already at work, prints the plan before anything launches, creates the sessions in the environment docs/work/claude-code-web.md declares, verifies each one, and reports its link. Supports a dry run and a slug filter; never finalizes, edits, commits, or pushes itself.
compatibility: Launches from a Claude Code on the web session through the claude-code-remote MCP server's create_session, get_session, and list_sessions tools, or from a local Claude Code session through claude --cloud under util-linux script, run on the default branch. The in-flight check reads open pull requests with an authenticated gh, or else the GitHub MCP server. With neither launch route the skill stops after the plan and prints each session's prompt for a manual start.
---

# Finalize tasks in the cloud

Take every task in one bucket of `docs/work/tasks/` and give each its own Claude
Code on the web session running `task-finalize`. Use this when several briefs are
waiting on finalization and the owner wants each interview ready in the cloud,
rather than run here one task at a time. `task-finalize` verifies one brief against
the code and settles its open questions with the owner, one per turn; this skill
fans that out, one task per session, and finalizes nothing itself.

Each session runs `task-finalize` through its verification and orientation card,
then stops. The owner opens the session at claude.ai/code, answers the questions
there, and lands the finalized brief from that session with `ship`. A landed brief
sits in `docs/work/tasks/finalized/`, where `task-implement-cloud` picks it up.

Run it from a Claude Code on the web session or from a local Claude Code session;
the two launch the sessions by different routes. The launch mechanics, both routes
included, are shared with `problem-plan-cloud` and `task-implement-cloud` and live in
[cloud dispatch](../problem-plan-cloud/cloud-dispatch.md). Read it before step 1; the
steps below say which of its sections to apply.

## Arguments

All optional, in any order, besides the shared slug filter and `dry-run`:

- a bucket name: `now`, the default, `soon`, or `later`. `finalized` is not
  dispatched, because those briefs are already finalized and the next stage is
  `task-implement-cloud`; `never` holds parked tasks nobody is watching; and
  `queued/` is a retired bucket, whose legacy briefs are recovered through
  `task-move`, never dispatched.

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/`, with the planning buckets `now/`, `soon/`,
  `later/`, and `never/`, and the lifecycle bucket `finalized/`. The shared
  [task bucket definitions](../task-create/bucket-definitions.md) say what each
  holds. A bucket's `README.md` is not a task.
- **The stage skill**: [`task-finalize`](../task-finalize/SKILL.md). Read its
  Phase 1 before step 3: it accepts a brief in any planning bucket or in
  `finalized/`, so every brief in the dispatched bucket is a valid argument, and
  its own Phase 3 stops a task that is already done or moot.

---

## Step 1 — Read the default branch and resolve the target

Apply cloud dispatch steps 1 and 2: snapshot `docs/work` from the default branch
and resolve the environment, repository, and session tools from the declaration.

## Step 2 — Inventory the bucket

List the bucket in the snapshot by explicit path and check the command's exit
status:

```bash
find "$snapshot/docs/work/tasks/<bucket>" -maxdepth 1 -type f -name '*.md' \
  ! -name README.md ! -name _TEMPLATE.md | sort
```

A missing bucket directory is reported as absent, not as empty. Narrow to the named
slugs when any were given; a named slug that matches no brief in that bucket is
reported, and when nothing matches, stop. An empty selection is a reported no-op.

Read each kept brief from the snapshot far enough to take:

- its H1, which becomes the session title `Finalize: <H1>`;
- the first sentence of its `**In brief**:` paragraph for the plan;
- its frontmatter `status`, `effort`, `priority`, and `dependencies`;
- how many open questions its `## Open questions` section holds, counting list
  items or paragraphs and ignoring HTML comments, so the plan shows which sessions
  carry an interview and which only verify and stamp;
- every other brief in the selection that its `dependencies` name, or whose
  `dependencies` name it. Those are the siblings step 5 tells each session about.

## Step 3 — Gates

1. **Being implemented.** `status: in-progress` means someone is executing the
   brief, and a finalize run would redesign it under them. Skip, and say that
   running `task-finalize` on it directly is the deliberate route when the
   implementation has stalled on a design question.
2. **In flight.** Apply cloud dispatch step 3 with the tag `task-finalize:<slug>`.

Nothing else is a gate here. A blocked task is dispatched, because the decision it
waits on may be exactly what the interview settles. An unmet dependency is
dispatched too: `task-finalize` records that the design rests on unlanded work.
Whether the task is already done or moot is `task-finalize`'s Phase 3 to decide
with the code open.

## Step 4 — Print the plan

Apply cloud dispatch step 4 with this table:

| Task | Title | Status, effort, priority | Open questions | Action | Related in this batch |
|---|---|---|---|---|---|
| `<bucket>/<slug>.md` | the H1 | from the frontmatter | the count from step 2 | dispatch, or skip with its reason | the sibling slugs and which way each dependency runs |

## Step 5 — Launch

Apply cloud dispatch step 5. The record kind is "task", the title is
`Finalize: <H1>`, the tag is `task-finalize:<slug>`, and the stage block is:

```text
Then run the task-finalize skill on this task:

/task-finalize <repository-relative path to the brief>

Follow that skill exactly, through its Phase 3 verification and its
orientation card, then stop and wait: the owner will open this session to
answer the open questions, one per turn, as the skill says. Do not answer them
for the owner, do not take the recommendations on their behalf, and do not skip
a phase. A Phase 3 stop, because the task is already done or no longer
applies, is a complete and useful result: report it and stop. At the commit
offer, the owner decides.
```

When step 2 found siblings, the sibling paragraph is:

```text
These tasks from the same bucket are being finalized at the same time, each in
its own session: <sibling slugs, and which way each dependency runs>. If a
decision here would change a sibling's premise, say so on the card and in the
summary, and leave the sibling's brief to its own session.
```

## Step 6 — Verify, then report

Apply cloud dispatch steps 6 and 7. The report's "what happens next" says each
session stops at its orientation card; that after `task-finalize`'s commit the
owner lands the brief from that session with `ship`; and that a landed brief moves
to `finalized/`, ready for `task-implement-cloud`. From a local session it also says
that a session cannot report a failed turn back to it, that checking on one is its
link at claude.ai/code or `get_run_log` on its session ID, and that archiving a
session at claude.ai/code before the interview loses no commit, because
`task-finalize` commits only after it.

## See also

- [Cloud dispatch](../problem-plan-cloud/cloud-dispatch.md) — the shared launch
  procedure
- [`task-finalize`](../task-finalize/SKILL.md) — the skill each session runs, and the
  owner of every finalization decision
- [`problem-plan-cloud`](../problem-plan-cloud/SKILL.md) — the stage before, which
  files the tasks
- [`task-implement-cloud`](../task-implement-cloud/SKILL.md) — the stage after, for
  finalized briefs
- [Task bucket definitions](../task-create/bucket-definitions.md) — what each bucket
  holds
