---
name: problem-plan-cloud
description: Send every problem record in one bucket of docs/work/problems/ (now/ unless another bucket is named) to the cloud for planning, one Claude Code on the web session per record, each running problem-plan on its record and stopping at the orientation card for the owner to continue there. Reads the records from the default branch, skips those with a Disposition line, a live task citing them, or a session or pull request already at work, prints the plan before anything launches, creates the sessions in the environment docs/work/claude-code-web.md declares, verifies each one, and reports its link. Supports a dry run and a slug filter; never plans, edits, commits, or pushes itself.
compatibility: Launches from a Claude Code on the web session through the claude-code-remote MCP server's create_session, get_session, and list_sessions tools, or from a local Claude Code session through claude --cloud under util-linux script, run on the default branch. The in-flight check reads open pull requests with an authenticated gh, or else the GitHub MCP server. With neither launch route the skill stops after the plan and prints each session's prompt for a manual start.
---

# Plan problems in the cloud

Take every record in one bucket of `docs/work/problems/` and give each its own
Claude Code on the web session running `problem-plan`. Use this when a bucket has
filled up and the owner wants the planning interviews waiting for them in the cloud,
rather than run here one record at a time. `problem-plan` decides one record in
conversation with the owner, and its card and interview hold one session's
attention by design; this skill fans that out, one record per session, and plans
nothing itself.

Each session runs `problem-plan` up to its orientation card and stops. The owner
opens the session at claude.ai/code, answers the interview there, and lands the
result from that session with `ship`.

Run it from a Claude Code on the web session or from a local Claude Code session;
the two launch the sessions by different routes. The launch mechanics, both routes
included, are shared with `task-finalize-cloud` and `task-implement-cloud` and live in
[cloud-dispatch.md](cloud-dispatch.md) beside this file. Read it before step 1; the
steps below say which of its sections to apply.

## Arguments

All optional, in any order, besides the shared slug filter and `dry-run`:

- a bucket name: `now`, the default, `soon`, or `later`. `never` is not dispatched,
  because those records are parked by the owner's explicit direction, and planning
  one is a deliberate single run of `problem-plan`;
- `include-planned`, which also dispatches the records step 3's first two gates
  would skip.

## Repo conventions (resolve first)

- **Problems root**: `docs/work/problems/`, with records in `now/`, `soon/`,
  `later/`, and `never/`, or directly under it as legacy unbucketed records. The
  shared [bucket definitions](../problem-create/bucket-definitions.md) and the
  `list-records.py` inventory beside them are read from the `problem-create`
  skill's **physical** directory, following every symlink first, per
  [skill path resolution](../../../docs/skill-path-resolution.md).
- **Tasks root**: `docs/work/tasks/`, whose buckets the planned gate searches.
- **The stage skill**: [`problem-plan`](../problem-plan/SKILL.md). Read its Phase 1
  and Phase 2 before step 3, so the gates applied here are the gates it applies,
  not a paraphrase of them.

---

## Step 1 — Read the default branch and resolve the target

Apply cloud dispatch steps 1 and 2: snapshot `docs/work` from the default branch
and resolve the environment, repository, and session tools from the declaration.

## Step 2 — Inventory the bucket

Run `python3 <physical-problem-create-dir>/list-records.py "$snapshot"` and check
its exit status: a failed inventory is a layout error to report, not an empty
bucket. Keep the records whose `bucket` is the requested one, narrowed to the named
slugs when any were given. A named slug that matches no record in that bucket is
reported; when nothing matches, stop. An empty selection is a reported no-op.

Read each kept record from the snapshot far enough to take:

- its H1, which becomes the session title `Plan: <H1>`;
- the first sentence of its `**In brief**:` paragraph for the plan, or, in a legacy
  record without one, its scope statement, labelled as a fallback;
- every link under its **See also** to another record in the same selection.

Those links are the siblings step 5 tells each session about. `problem-plan` treats
a record whose See also names a neighbouring flaw in the same construct as a pair,
and two sessions each absorbing the other's record is the one collision this
fan-out can cause.

## Step 3 — Gates

`problem-plan` opens with gates that end a run before any planning. A session that
stops at one was a launch for nothing, so apply the same checks here, by the same
means, against the snapshot. Skip what they catch:

1. **Decided.** The record carries a `**Disposition**:` line. Skip, quoting the
   line, unless `include-planned` was given.
2. **Planned.** Search for the record's filename without `.md` across
   `docs/work/tasks/now`, `soon`, `later`, `finalized`, `parked`, `queued` where it
   exists, and `docs/work/handoffs/` where it exists, in the snapshot, by explicit
   path, never a recursive search from the root whose omissions are invisible. A
   hit from a live task: skip as "already planned: see `<task>`", unless
   `include-planned` was given. A hit from `parked/` only is parked work:
   skip and quote its parking note.
3. **In flight.** Apply cloud dispatch step 3 with the tag `problem-plan:<slug>`.
   `include-planned` does not override this gate: a second session on a record
   already being planned is a duplicate, not a re-plan.

Nothing else is a gate here. Whether the flaw is still present, likely fixed, or
has drifted is `problem-plan`'s status gate to decide with the record open, and a
record it routes to `kaizen-resolve` was still usefully dispatched.

## Step 4 — Print the plan

Apply cloud dispatch step 4 with this table:

| Record | Title | Action | Siblings in this batch |
|---|---|---|---|
| `<bucket>/<slug>.md` | the H1 | dispatch, or skip with its reason | the sibling slugs from step 2 |

## Step 5 — Launch

Apply cloud dispatch step 5. The record kind is "problem record", the title is
`Plan: <H1>`, the tag is `problem-plan:<slug>`, and the stage block is:

```text
Then run the problem-plan skill on this record:

/problem-plan <repository-relative path to the record>

Follow that skill exactly, through its orientation card, then stop and wait:
the owner will open this session to answer the interview, one question per
turn, as the skill says. Do not answer the interview for them, do not take the
recommendations on their behalf, and do not skip a gate. A gate that ends the
run, such as already planned, already decided, or likely fixed, is a complete
and useful result: report it and stop.
```

When step 2 found siblings, the sibling paragraph is:

```text
These records from the same bucket are being planned at the same time, each in
its own session: <sibling slugs>. If the skill's pair rule would pull one of
them into this run, say so on the card and let the owner decide whether to
plan the pair here or leave it to its own session.
```

## Step 6 — Verify, then report

Apply cloud dispatch steps 6 and 7. The report's "what happens next" says each
session stops at its orientation card, and that after `problem-plan`'s commit the
owner lands the plan from that session with `ship`. From a local session it also says
that a session cannot report a failed turn back to it, that checking on one is its
link at claude.ai/code or `get_run_log` on its session ID, and that archiving a
session at claude.ai/code before the interview loses no commit, because
`problem-plan` commits only after it.

## See also

- [Cloud dispatch](cloud-dispatch.md) — the shared launch procedure
- [`problem-plan`](../problem-plan/SKILL.md) — the skill each session runs, and the
  owner of every planning decision
- [`task-finalize-cloud`](../task-finalize-cloud/SKILL.md) — the next stage, for the
  tasks a plan files
- [Problem bucket definitions](../problem-create/bucket-definitions.md) — the
  buckets and the inventory tool
- `docs/work/claude-code-web.md` in the consuming repository — the environment the
  sessions are created in, and the turn-one check
