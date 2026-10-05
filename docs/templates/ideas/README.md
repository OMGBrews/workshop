# Ideas

Directions for this project worth keeping in writing — possible features,
designs, or whole projects — even when nothing is planned for them. An idea
document describes a possible future, not work in progress; many will never be
built, and that is fine. This README was seeded from the shared Workshop tree's
`docs/templates/ideas/README.md`; the copy is this repository's own.

## When to add a document

Add one when:

- A direction is worth preserving, even though nothing is planned for it.
- You want to think a capability through before deciding whether to commit to
  it.
- The project considered a path and may come back to it.
- A thought in `docs/work/thoughts/` turned out to be a long-lived maybe. The
  `thought-finalize` skill writes it here once the user confirms.

Do not add one for:

- **Concrete work with a statable done-condition** → a task in
  `docs/work/tasks/`.
- **A flaw that exists today** → a problem record in `docs/work/problems/`.
- **Friction in how we build** → the kaizen journal in
  `docs/work/kaizen/journal/`.

## Keep documents in the idea genre

Lead with the problem and the proposed direction, sketch the shape, and
surface the open questions. An idea may sit here indefinitely; it needs no
status, owner, or target date.

**Do not mirror shipped state.** What is built is documented with the feature
itself. An idea document that tracks the implementation rots silently against
the code and leads readers to mistake a possibility for the system. Where an
idea has to be anchored against today's implementation, a short pointer to the
relevant feature document is enough.

## Document structure

One flat folder: one kebab-case file per idea, with no date prefix. Start from
the shared Workshop tree's `docs/templates/idea-doc.md` — a title and scope
statement, then problem statement, proposed direction, open questions, and see
also. This README keeps no index: low-friction capture matters more here than
indexing, and a hand-kept table drifts.

## When a document graduates

An idea that is being actively pursued has outgrown this folder:

- Split its concrete work into tasks once the work is actionable.
- Move it to wherever the repository keeps designs in progress once a real
  design is being worked through.

A graduated document leaves this folder. Never keep two copies in sync.

## See also

- `docs/work/thoughts/` — the one- or two-sentence notes an idea often starts as
- `docs/work/tasks/` — concrete, actionable work
- `docs/work/problems/` — flaws that exist today
