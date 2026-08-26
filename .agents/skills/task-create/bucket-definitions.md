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

A repo's `<tasks>/README.md` bucket list and its `never/README.md` one-liner are
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
| `never/` | Parked — see below | Promoted to any bucket by `/task-move` |

**Completed tasks are deleted, not archived.** Git preserves the history and
`git log --diff-filter=D` finds them. There is no `done/` bucket and no `done`
status.

## `finalized/`

`<tasks>/finalized/` holds briefs that passed `/task-finalize` and are available
for supervised implementation. Finalization moves the brief here automatically;
`/task-implement` removes it on completion, and `/task-move` may hand it to
`queued/` where an autonomous runner exists.

This is a lifecycle bucket, not a fifth planning horizon. It sits outside queue
shape and reprioritization, and `/task-next` considers it before unfinalized work.
A usable `finalized-at:` stamp is required for every brief in the directory. The
name describes the recorded finalization event, not a permanent freshness claim:
the implementer still checks what changed after that commit.

### `never/` is parked, not terminal

A task lands in `never/` for one of three reasons:

- **Rejected** — considered and decided against, filed because the rejection itself
  is worth preserving so it is not re-litigated.
- **Deferred indefinitely** — real work with no date on it, waiting on something
  that may never come or on a reminder far enough out that a live bucket would only
  make noise.
- **Kept for reference** — not work any more, but the document is worth keeping
  where task-shaped things live.

**A task in `never/` is parked, not dead.** `/task-move` accepts `never` as both a
source and a target with no special handling, and the return path is ordinary. What
the bucket really means is *nobody is watching this one*: the ranking and
rebalancing skills skip it, so a task parked there will not resurface on its own.
Someone has to ask for it back.

A parked task keeps its real `status:`, which for work nobody is doing is
`not-started`. `never/` holding an `in-progress` task is a contradiction, and
`/task-status` reports it as one.

## `queued/`

`<tasks>/queued/` exists only in repos running the autonomous task-queue runner — a
deliberate per-repo opt-in, never scaffolded by default. It holds briefs the runner
has claimed or will claim, so it belongs to the runner rather than to a human triage
pass: `/task-move` moves a task in once `/task-finalize` has made it pass readiness,
and the runner moves it out, deleting the brief on completion or setting it aside in
`queued/blocked/`.

## Queue shape

The planning buckets aim for **roughly 3 tasks in `now/`, 3 in `soon/`, and the rest in
`later/`**. It is a soft target rather than a quota: `/task-reprioritize` owns the
tolerances and the fill order that enforce it, and names its own deviations.

`finalized/`, `never/`, and `queued/` sit **outside** that shape. `/task-reprioritize`
never moves a task in or out of them. `/task-next` prefers `finalized/`, ignores
`never/`, and leaves `queued/` to the autonomous runner. Explicit moves out of these
buckets belong to `/task-move`; it enforces the readiness rules on the way into
`queued/`.

## See also

- [`_TEMPLATE.md`](_TEMPLATE.md) — the canonical task template, in this directory
- [`../task-reprioritize/ranking-rubric.md`](../task-reprioritize/ranking-rubric.md) — how tasks are ranked *within* the shape this document defines
