---
name: task-implement-cloud
description: Send the finalized tasks a Claude Code on the web session can actually finish to the cloud, one session per task running task-implement. Reads docs/work/tasks/finalized/ from the default branch, skips briefs with open questions, a blocked status, an unmet dependency, or a session or pull request already at work, then classifies every remaining acceptance criterion against what docs/work/claude-code-web.md says a cloud session can and cannot do. Only tasks whose remaining work is all cloud work are dispatched; tasks whose remaining work needs something that page says a cloud session cannot do, such as a device, a live service, or a build only a host can make, are reported with the criteria that need a host. Holds back tasks whose files overlap so parallel sessions do not collide. Supports a dry run, a slug filter, and an opt-in for the cloud part of a mixed task; never implements, commits, or pushes itself.
compatibility: Launches from a Claude Code on the web session through the claude-code-remote MCP server's create_session, get_session, and list_sessions tools, or from a local Claude Code session through claude --cloud under util-linux script, run on the default branch. The in-flight check reads open pull requests with an authenticated gh, or else the GitHub MCP server. With neither launch route the skill stops after the plan and prints each session's prompt for a manual start.
---

# Implement tasks in the cloud

Take the finalized briefs in `docs/work/tasks/finalized/`, work out which of them a
Claude Code on the web session can finish, and give each of those its own session
running `task-implement`. Use this when finalized work has piled up and the owner
wants the cloud to carry what it can. This skill implements nothing itself. Its job
is the sorting: a session given a task it cannot finish writes code it cannot
verify, ticks nothing, and leaves the brief in progress for a host anyway.

Each session runs `task-implement` to the end of its verification and stops at the
close-out question, where the owner confirms the task finished. The owner then lands
the work from that session with `ship`.

Run it from a Claude Code on the web session or from a local Claude Code session;
the two launch the sessions by different routes. The launch mechanics, both routes
included, are shared with `problem-plan-cloud` and `task-finalize-cloud` and live in
[cloud dispatch](../problem-plan-cloud/cloud-dispatch.md). Read it before step 1; the
steps below say which of its sections to apply.

## Arguments

All optional, in any order, besides the shared slug filter and `dry-run`:

- `cloud-part`, which also dispatches each **split** task from step 4 for its cloud
  criteria only. The session does that part, leaves the host criteria open, and
  writes a resume point for a host session. Without it, a split task is reported,
  not dispatched.

There is no bucket argument. `task-implement` reads finalized briefs first, and an
unfinalized brief needs `task-finalize-cloud` before it is worth a session.

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/`. This skill reads `finalized/`; dependency
  checks also read `now/`, `soon/`, `later/`, `parked/`, and a legacy `queued/`
  where one survives. The shared [task bucket definitions](../task-create/bucket-definitions.md)
  say what each holds.
- **What a cloud session can do**: the section of that name in the repository's
  `docs/work/claude-code-web.md`, with the list of what a cloud session cannot do
  beneath it. That page is the authority step 4 classifies against, and it may
  name further authorities, such as a test README that says which harnesses run
  without a host, and carry its own table of examples for this skill's step 4.
  `docs/work/definition-of-done.md` says which checks the changed paths require.
  Read every one of them from the snapshot. A declaration without that section
  gives this skill nothing to classify against: stop, and name the section the
  repository needs to add.
- **The stage skill**: [`task-implement`](../task-implement/SKILL.md). Read its
  Phase 1, Phase 2, and Phase 6 before step 3: step 3's gates are the refusals in
  its Phases 1 and 2, and the session stops at its Phase 6 close-out question.

---

## Step 1 — Read the default branch and resolve the target

Apply cloud dispatch steps 1 and 2: snapshot `docs/work` and the mod scripts README
from the default branch, and resolve the environment, repository, and session tools
from the declaration.

## Step 2 — Inventory the finalized briefs

List the bucket in the snapshot by explicit path and check the command's exit
status:

```bash
find "$snapshot/docs/work/tasks/finalized" -maxdepth 1 -type f -name '*.md' \
  ! -name README.md ! -name _TEMPLATE.md | sort
```

A missing directory is reported as absent, not as empty. Narrow to the named slugs
when any were given; a named slug that matches no finalized brief is reported, and
when nothing matches, stop. Read each kept brief from the snapshot end to end: its
H1, frontmatter, `## Scope`, the acceptance criteria between the `AC:BEGIN` and
`AC:END` sentinels, `## Stopping conditions`, `## Recommended solution`, and any
`## Open questions`, `## Blocked`, or `## Resume point` section.

## Step 3 — Readiness gates

Apply these in order. The first that fires decides the task's row, and a skipped
task is not classified.

1. **Open questions.** A `## Open questions` section holding anything other than
   whitespace and HTML comments. `task-implement` refuses these in its Phase 2.
   Skip, and name `task-finalize` as the route.
2. **Blocked.** `status: blocked`. Skip, quoting the first sentence of the brief's
   `## Blocked` section.
3. **Unmet dependency.** For each slug in `dependencies:`, look for a brief of that
   name under every tasks bucket in the snapshot, by explicit path. A live brief,
   in `parked/` too, means the dependency has not landed: skip, naming it. A missing
   brief is not proof of completion, because `task-implement` requires history to
   tell completion from a rename. Find the newest commit that removed it with
   `git log --diff-filter=D --format=%h -n 1 "$default" -- ":(glob)docs/work/tasks/**/<slug>.md"`,
   then read that commit with `git show --stat --format=%s <sha>`. A close-out
   that deletes the brief without adding another one is completion. A commit that
   adds a brief under another name is a rename, so the dependency is unmet under its
   new name, and the dependent brief needs updating. No removing commit at all is a
   typo. Skip both, and report each as a dependency the brief names wrongly.
4. **In flight.** Apply cloud dispatch step 3 with the tag `task-implement:<slug>`.

`status: in-progress` is not a gate. A cloud-part session leaves its brief in
progress with a `## Resume point` for a host, so in progress on a finalized brief
usually means "waiting on a host", which step 4 reads from the resume point itself.

## Step 4 — Classify what remains against what a cloud session can do

This step decides what is dispatched, so it is done per item, with evidence, never
by the brief's title or its mod.

**The work items** are:

- every acceptance criterion whose marker is anything other than exactly `[x]`,
  including `[~]`;
- the evidence `## Stopping conditions` requires before the task counts as done;
- for an in-progress brief, each step of its `## Resume point`.

**Give each item one verdict**, and record a short quote from the item and the line
of the capability authority it rests on:

- **Cloud**: a cloud session can both make the change and produce the evidence
  that the item asks for.
- **Host**: the change or its evidence needs something the authority says a cloud
  session cannot do.
- **Unclear**: the brief does not say enough to decide. Name what would decide it.

These signals are leads for reading an item, not verdicts. Where they disagree with
the authority, the authority wins, and the disagreement is reported as a defect in
this skill.

| An item that needs | Usually | The authority's line |
|---|---|---|
| Behaviour observed in a running application, on a device, on a server, with another user connected, across a restart, or by the owner's judgment of how it feels in use | host | the line that names the application, device, or server a cloud session cannot run |
| A check a document the declaration names as an authority lists as needing an environment a cloud session lacks | host | that document's line, through the declaration that names it |
| A build, asset, or file the declaration says only a host can produce, such as one that needs a licensed tool, a local toolchain, or a file tracked by Git LFS | host | the declaration's line for it |
| A live service, a deployment, a publication or upload, or a credential kept outside the repository | host | the declaration's line for it, usually one that names a gitignored key or token |
| A code or documentation change, a build the declaration lists as available, a check it or the definition of done marks as runnable without a host, a decompile, or the link check | cloud | what a cloud session can do |
| A decision or wording only the owner can give, with nothing a host would run | cloud | the owner answers in the session |

A repository that carries its own table of examples under its capability section
is read first; its rows are the same shape, filled with the repository's own
components and harnesses, and they outrank the generic rows above.

Three rules settle the common hard cases:

- **The evidence decides, not the code.** A criterion whose code is written and
  builds, but which asks for an observation in the running application, is host. An
  annotation such as "code change made and builds; unverified in the app" is exactly
  that shape.
- **A stopping condition that allows "report it as unavailable" does not make the
  item cloud.** The criterion still cannot be ticked without the evidence.
- **Preparing a release is cloud work; publishing and deploying are host.** A
  version bump and changelog can be written in the cloud, though the cloud ship
  policy sends that pull request to the owner's review.

**Then give the task one verdict:**

| Items | Verdict | Dispatched |
|---|---|---|
| All cloud | **cloud** | yes, for the whole task |
| At least one host and at least one cloud | **split** | only with `cloud-part`, for the cloud items; unclear items stay with the host items |
| At least one host and no cloud | **host** | no |
| No host, and at least one unclear | **unclear** | no; the report names what would decide each item |

## Step 5 — Hold back overlapping tasks

Parallel sessions that edit the same files land conflicting pull requests. Give
each dispatchable task a footprint: the paths its `## Scope` names, plus those its
`## Recommended solution` names, and, for a task that bumps a component's version
or changelog, the files the repository keeps that version and changelog in. A brief that names
no paths at all has an unknown footprint, which overlaps everything. Two footprints
overlap when they share a file, or one names a directory that contains the other's
file.

Sort the dispatchable tasks by `priority`, high first; then a task another
dispatchable task depends on; then smaller `effort`; then slug. Walk that order and
dispatch each task whose footprint overlaps none already chosen. Each other task is
**held**, naming the task it overlaps, and goes out in a later run once that one
lands.

## Step 6 — Print the plan

Apply cloud dispatch step 4 with this table:

| Task | Title | Gate | Verdict | Work that needs a host | Action |
|---|---|---|---|---|---|
| `finalized/<slug>.md` | the H1 | passed, or the gate that skipped it | cloud, split, host, unclear, or none for a gated task | one short quote per host item, with the capability it needs | dispatch, dispatch cloud part, held, or skip |

## Step 7 — Launch

Apply cloud dispatch step 5. The record kind is "task", and the tag is
`task-implement:<slug>`. A **cloud** task is titled `Implement: <H1>` and gets this
stage block:

```text
Then run the task-implement skill on this task:

/task-implement <repository-relative path to the brief>

The dispatcher classified every remaining item of this task as work a cloud
session can do and evidence it can produce:
<one line per item: a short quote and the evidence it needs>

Build and check with the commands in docs/work/claude-code-web.md under "What
a cloud session can do". Follow task-implement exactly. If an item turns out to
need what a cloud session cannot do, such as <the declaration's list of what
a cloud session cannot do, in a few words>, do not tick it on substitute
evidence: take the skill's Blocked path and name the item and what
it needs. When the work is done and verified, stop at the skill's close-out
question and wait: the owner will open this session to confirm.
```

A **split** task, sent only under `cloud-part`, is titled
`Implement (cloud part): <H1>` and gets this stage block:

```text
Then run the task-implement skill on this task, for part of it only:

/task-implement <repository-relative path to the brief>

The owner asked for the cloud part of this task. Do these items, which a cloud
session can both do and evidence:
<one line per cloud item>

Leave these unticked, because they need what a cloud session cannot do:
<one line per host or unclear item, with what it needs>

Follow task-implement through its verification and implementation phases for
the cloud items only, ticking each on evidence. Build and check with the
commands in docs/work/claude-code-web.md under "What a cloud session can do".
Do not take the close-out, because the task is not finished. Keep `status:
in-progress`, and write or replace the brief's `## Resume point` section: what
this session did, the command and verdict line of each check it ran, and
numbered steps for a host session to finish the rest. Commit that with the
work, then report and stop.
```

When more than one task is dispatched, the sibling paragraph is:

```text
These tasks are being implemented at the same time, each in its own session:
<the other dispatched slugs>. Their briefs name no files this task's brief
names. If you find you must edit a file one of them names, say so before
editing it.
```

## Step 8 — Verify, then report

Apply cloud dispatch steps 6 and 7, and add the classification ahead of the
skipped list:

- **Classified**, one line per task that passed the gates: its verdict, and for
  split, host, and unclear, the items that kept it from the cloud, each with the
  capability it needs. These lines are what tells the owner which tasks wait on a
  host session.
- **Held**, one line per held task, naming the task it overlaps.

The report's "what happens next" says each full session stops at its close-out
question, and each cloud-part session at its resume point; that the owner lands the
work from that session with `ship`; and that the cloud ship policy sends a pull
request that touches a path the policy excludes, such as a version bump, to the
owner's review rather than merging it. From a local session it also says that a session
cannot report a failed turn back to it, that checking on one is its link at
claude.ai/code or `get_run_log` on its session ID, and that a session should be archived
at claude.ai/code only once its work has landed with `ship` or been given up,
because its commits may exist nowhere else until `ship` pushes them.

## See also

- [Cloud dispatch](../problem-plan-cloud/cloud-dispatch.md) — the shared launch
  procedure
- [`task-implement`](../task-implement/SKILL.md) — the skill each session runs, and
  the owner of every close-out
- [`task-finalize-cloud`](../task-finalize-cloud/SKILL.md) — the stage before, which
  fills `finalized/`
- `docs/work/claude-code-web.md` in the consuming repository — the capability
  authority, and the build commands each session uses; its shape is the
  [Claude Code Web declarations](../../../docs/claude-code-web.md) standard
- `docs/work/ship/cloud.md` in the consuming repository — which implementation pull
  requests merge on their own and which wait for review
