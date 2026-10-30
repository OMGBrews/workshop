# Task bucket definitions

What each task bucket means, the shape the queue aims for, and who moves a task out
of each one. Read this from any shared task skill that needs to say what a bucket
*is*, and from a repo's own tasks README — it is the single definition all of them
reference, so bucket meaning cannot drift between the skills and the repos.

The file lives inside the `task-create` skill because that skill scaffolds the bucket
directories and writes their READMEs, following the `_TEMPLATE.md` precedent (a
canonical file inside one skill, referenced across skill boundaries). It is a shared
reference, not a private one: edit it here and every skill that points at it changes
together.

## This document is the authority

A repo's `<tasks>/README.md` bucket list and its `parked/README.md` one-liner are
**courtesy summaries** — they exist so someone landing in a directory learns what it
holds without following a link. Where a summary and this document disagree, this
document is right and the summary is the bug to fix. A summary that grows past a
sentence per bucket has started becoming a second definition; trim it back to a
pointer.

## The four planning buckets

Tasks are filed by **how soon we intend to work them** — not by how important they
are, and not by what they touch.

| Bucket | Holds | How a task leaves |
|---|---|---|
| `now/` | Active work — in progress, or the next thing to pick up | Completed, or demoted by `/task-reprioritize` |
| `soon/` | Planned — starts once current work clears | Promoted to `now/` by `/task-reprioritize`, or moved by `/task-move` |
| `later/` | Backlog — valuable, not yet scheduled | Promoted by `/task-reprioritize` when the queue has room, or by `/task-move` |
| `parked/` | Deferred work nobody is watching — see below | Promoted to any bucket by `/task-move` |

**Completed tasks are deleted, not archived.** Git preserves the history and
`git log --diff-filter=D` finds them. There is no `done/` bucket and no `done`
status.

## `finalized/`

`<tasks>/finalized/` holds briefs that passed `/task-finalize` and are available
for supervised implementation. Finalization moves the brief here automatically;
`/task-implement` removes it on confirmed completion.

This is a lifecycle bucket, not a fifth planning horizon. It sits outside queue
shape and reprioritization, and `/task-next` considers it before unfinalized work.
A single well-formed `finalized-at:` stamp is required for every brief in the
directory. It records a conservative comparison baseline shared by the inspected
commit and a freshly fetched default branch where one can be established; otherwise
it records the inspected commit with limited durability disclosed at finalization.
The name describes the recorded finalization event, not a permanent freshness claim:
the implementer checks what changed after a usable baseline, and fully re-verifies
the brief when the stamped history is unavailable or outside current ancestry.

### `parked/` holds deferred work nobody is watching

`parked/` sits below `later/`: real work, set aside with no date on it, that no
skill will bring back on its own. The ranking and rebalancing skills skip it, so
a parked task resurfaces only when someone asks for it. The return path is
ordinary: `/task-move` accepts `parked` as both a source and a target.

**Every parked brief carries a parking note.** It is a `## Parked` section placed
immediately after the `**In brief**:` paragraph, with two lead-ins:

```markdown
## Parked

**Why**: <why the work was set aside>

**Unpark when**: <the condition that should bring it back>
```

When the unpark condition is a date, the brief may also carry the optional
frontmatter field `unpark-after: YYYY-MM-DD` so tooling can sort and flag it. The
field supplements the section; it never replaces it.

**A parked brief's filename never changes** on park or unpark. The slug is how
`dependencies:`, the readiness checker's dependency search, `/task-next`, and the
cloud dispatch skills identify a task, so a date or marker in the filename would
break every reference to it. Dates go in `unpark-after:`.

**Rejected briefs are deleted, not parked.** A task considered and decided
against is removed the way a completed one is, with the rationale in the commit
message or a decision record. Where a rejection is worth keeping in place, the
brief carries a `## Rejection rationale` section, and such a brief leaves
`parked/` only by a deliberate move of that one task — never by a bulk or
filter-driven move, which would revive the rejected work along with the deferred.

**`blocked` is a status, not a bucket.** A brief waiting on an external
dependency carries `status: blocked` and stays in its horizon, where
`/task-reprioritize` already demotes it from `now/` to `soon/` and exempts a
blocked in-focus brief from the trim. It is parked only when nobody is watching
for the unblock, and its parking note then names the unblock as the unpark
condition.

A parked task keeps its real `status:`, which for work nobody is doing is
`not-started` or `blocked`. `parked/` holding an `in-progress` task is a
contradiction, and `/task-status` reports it as one.

## Retired `queued/` bucket

Autonomous task execution is retired. Do not create or promote work into
`queued/`. Recover surviving briefs through the [retirement guidance](../task-queue/README.md).

## Queue shape

The planning buckets aim for **roughly 3 tasks in `now/`, 3 in `soon/`, and the rest in
`later/`**. It is a soft target rather than a quota: `/task-reprioritize` owns the
tolerances and the fill order that enforce it, and names its own deviations.

`finalized/` and `parked/` sit **outside** that shape. `/task-reprioritize`
never moves a task in or out of them. `/task-next` prefers `finalized/` and
ignores `parked/`. Explicit moves out belong to `/task-move`.

## See also

- [`_TEMPLATE.md`](_TEMPLATE.md) — the canonical task template, in this directory
- [`docs/focus-document.md`](../../../docs/focus-document.md) — the contract for the optional direction document beside the buckets
- [`../task-reprioritize/ranking-rubric.md`](../task-reprioritize/ranking-rubric.md) — how tasks are ranked *within* the shape this document defines
