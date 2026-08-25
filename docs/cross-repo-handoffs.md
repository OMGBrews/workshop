# Cross-repo handoffs

How one repository asks another to do work: where the request is written, how the
other side finds out it is waiting, and when it dies. Read this before writing up
a request for a repo you are not standing in — whether you are a human, an
interactive session, or an autonomous worker.

## The rule

**A handoff is an ordinary task document, filed in the receiving repo's task
queue.** There is no separate handoff genre, no special directory on the
receiving side, and no second status mechanism.

That is the whole convention, and it is a deletion rather than an addition.
Status, triage, priority, splitting one ask into several, indexing, and
retirement are all things the shared task system already does in every repo. A
parallel "handoff document" genre re-implements each of them worse: status as a
prose note at the top of the file, an index row somebody has to remember to
edit, and no queue at all. Both sides of the fleet's real handoffs had already
converged on writing them in the task template before this was written down.

## Writing one

Use the shared task template, exactly as for any other task in the target repo:

- **Name it like a task** — verb-first kebab slug, chosen by the author. That
  slug is the citation key for the document's whole life. **Nobody renames it,
  including the receiver.** A rename on receipt is how a citation ends up
  matching neither name.
- **Write the acceptance criteria from the requester's point of view** — what
  must be true for the asking repo to consider itself unblocked. The receiver
  may add its own; it does not need the requester's to be implementation steps.
- **Address it in frontmatter**:

  | Key | Value | When it is present |
  |-----|-------|--------------------|
  | `handoff-from:` | `owner/repo` of the asking repo | On a received brief, for its whole life |
  | `handoff-to:` | `owner/repo` of the target repo | **Only while the brief is undelivered** |

  The `handoff-to:` invariant is what makes discovery possible: any tracked file
  carrying it is, by definition, still awaiting routing. Both keys are optional
  extras — the task skills and the queue runner read the fields they name and
  ignore the rest, so a brief carrying them is an ordinary task everywhere else.

## Delivering it

Filing is not delivery. A brief written into a tree nobody is told about is
indistinguishable from one never written — that is the failure this convention
exists to close, and it has happened. There are two legs, and which one you are
on is decided by a fact about your session, not a preference.

### Sighted — the receiving repo is on your filesystem

The normal case when working from a workspace that holds several repos.

**Write the task directly into the receiving repo's `<tasks>/soon/`** with
`handoff-from:`, and commit it there. Delivery and filing are the same act.

- **Never into `queued/`.** Receiver triage is mandatory: the autonomous worker
  must not pick up an ask nobody in the receiving repo has read.
- **`priority:` is a suggestion**, not an instruction. The receiver reranks it
  by its own rubric.

### Blind — you cannot see the receiving repo

A container scoped to one project, or a cloud session with no checkout of the
target and no credentials for it. Do not invent a channel: opening an issue
fails on exactly the token scope that made the session blind in the first place.

**Write the same task-shaped brief into your own repo's
`docs/work/handoffs/`**, with `handoff-to:`, then **commit and push it**.
Filing is complete only when the brief is on your remote — an unpushed draft is
not yet filed, and nothing will find it.

The workspace index repo is the only party that can see every repo at once, so
it is the announcer. Its status pass sweeps every clone for tracked files
carrying `handoff-to:` in their frontmatter and reports each one as pending
until it is routed. That makes delivery a **polling contract**: a repo does not
need a channel to the index repo, it needs this document to say "file it here,
and the sweep collects it."

The sweep is **content-keyed, not location-keyed** — it matches the frontmatter
key wherever the file sits. A brief filed somewhere else for a locally sensible
reason is still found. Prefer `docs/work/handoffs/` anyway, because a reader
looking for one should not have to run a sweep.

### Routing a pending brief

A session that can see both repos moves it: file the task into the receiving
repo's `<tasks>/soon/`, flip `handoff-to:` to `handoff-from:`, and delete the
sender's outbox copy — one logical change, so the brief is never both pending
and delivered.

## Retention, status, and death

- **The sender keeps no standing copy.** Its stake in the outcome is its own
  follow-up task — consume the fix, bump the pin — which cites the handoff by
  slug. Git history preserves the outbox copy; a live second copy only rots.
- **Status is the task's `status:` field**, read by the same skills that read
  every other task's. There is no prose status line to keep in sync with an
  index row, because there is no index row.
- **One ask may become several tasks.** That is ordinary receiver triage: split
  by risk or by surface, and have each resulting task cite the origin slug.
- **The brief dies on completion**, like any task, in the commit that finishes
  the work. Anything durable in it — a decision, a constraint, a measured
  number — graduates into the receiving repo's own documentation first. A
  completed brief kept "for provenance" is an archive nobody reads and an index
  entry that goes stale.

## Citing one

**Cite a handoff by backticked slug, never by path or link.** A slug survives
the document's deletion; a path does not, and a link breaks the moment the work
ships.

When retiring a brief, a filename search is **not** a sufficient control. The
references that matter are usually the ones written in prose — "the upstream
handoff", "their brief" — which match no search for a filename. Grep the slug,
then read for the phrases too.

## Request/result pairs

A request travelling one way and a result coming back is the same genre, handled
the same way: the request travels as a handoff task, and the result travels back
as one. The **requester** keeps the returned result as provenance, in its own
documentation, indexed like any other document it owns. The responder keeps
nothing — it is the sender of the result, and senders keep no standing copy.

## What this does not govern

The word "handoff" is overloaded. A customer-facing ownership-transfer
procedure, a shift handover runbook, or any other document that happens to use
the word is out of scope here: this convention governs **requests for work
between repositories** and nothing else. Do not add addressing frontmatter to
those, and do not expect the sweep to care about them.

## See also

- [`definition-of-done.md`](definition-of-done.md) — the required evidence a receiving repo
  applies to the work a handoff asks for; a brief never restates them
- [`signal-hygiene.md`](signal-hygiene.md) — why "I filed it" is not "it was
  delivered" until something you can read says so
