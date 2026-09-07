---
status: not-started
effort: small
priority: medium
dependencies: [reshape-the-definition-of-done-convention]
---

# Point shared guidance at the definition-of-done schema

**In brief**: Several shared instructions tell an agent to go and satisfy the
project's finish-line page before landing work. Some of them point at a location
that page no longer lives at, and none of them knows the page is about to gain a
fixed set of sections. This task repairs the stale pointers and teaches each
instruction which part of the page it needs — the landing rules, or the list of
files that count as documentation-only — without copying the page's rules into
the instruction, where they would drift.

## Goal

Update the task-implement, task-queue, ship, and shipping-convention guidance so
each consumer reads the reshaped `docs/work/definition-of-done.md` by its real
path and by the section it needs, while introducing no second copy of the schema.

## Context

This is Phase 2 of hq's fleet verification standardization plan
(`docs/planning/fleet-verification-standardization.md` in hq) and depends on the
schema fixed by `reshape-the-definition-of-done-convention`.

The plan names the drift directly: the task-implement skill "still cites
`<tasks>/definition-of-done.md`". At HEAD, `.agents/skills/task-implement/SKILL.md`
gives the correct path in its conventions list ("`docs/work/definition-of-done.md`
where it exists") and the stale one in its Phase 6 step ("Satisfy
`<tasks>/definition-of-done.md` where it exists"). The task-queue worker's
`execution-discipline.md` `definition-of-done` block tells the worker to "look
for a `definition-of-done.md` in the tasks directory (the parent of your brief's
`queued/`)", which is the pre-`docs/work/` location; `initial-prompt.md` includes
that block mid-paragraph, and `run.sh` documents the include, so the block's
first line must stay a single word.

`docs/shipping-conventions.md` already reads the file by its current path and
refers to the `DOCS-ONLY` declaration through `Tools/docs-only-diff.sh`; once the
schema fixes that block's position and adds landing-route and enforcement
fields, the conventions should name the sections a session consults rather than
paraphrasing them. `docs/harness-agnostic-repos.md`, `docs/work-directory.md`,
`docs/cross-repo-handoffs.md`, and `docs/claude-code-web.md` link the
convention and are link-target checks only.

The rule this task serves is the plan's own: one source, consumed by reference,
never a synchronized copy.

## Scope

- `.agents/skills/task-implement/SKILL.md` — Phase 6 citation and the
  applicable-requirements table row.
- `.agents/skills/task-queue/execution-discipline.md` — the `definition-of-done`
  block, keeping the single-word first line the include depends on.
- `.agents/skills/ship/SKILL.md` — wherever it consults required evidence before
  opening a pull request.
- `docs/shipping-conventions.md` — which sections of the declaration a session
  reads to gather evidence and choose a landing route.
- A grep across `docs/` and `.agents/skills/` for `definition-of-done` to confirm
  no other consumer paraphrases the six sections or the axes.

## Acceptance criteria
<!-- AC:BEGIN — DO NOT REMOVE: /task-finalize, /task-move, and the task-queue worker parse the AC list between these sentinels. -->

- [ ] No shared skill or document cites `<tasks>/definition-of-done.md` or "the
      tasks directory" as the file's location; every citation names
      `docs/work/definition-of-done.md`.
- [ ] task-implement, the task-queue worker block, and ship each name the
      section of the declaration they consume (landing requirements, and the
      `DOCS-ONLY` block where relevant) and link the convention for everything
      else.
- [ ] No consumer carries a copy of the six-section list, the axis values, or
      the profile table; a grep for those terms outside `docs/definition-of-done.md`,
      `docs/verification-terminology.md`, and `docs/verification-profiles.md`
      finds only links and section names.
- [ ] The task-queue include still renders: the `definition-of-done` block's
      first line is one word and `tests/run-tests.sh` passes.
- [ ] `make check` passes in a standalone clone.

<!-- AC:END -->

## Stopping conditions

Done when the acceptance criteria hold at HEAD and `make check` exits 0 in a
standalone clone. Stop and report if a consumer needs more than the section name
and a link to do its job; that is a schema gap for the convention brief, not a
reason to paraphrase.

## Out of scope

- Changing what any consumer requires of a session; only where it reads and how
  it cites.
- The conformance checker (`add-a-definition-of-done-conformance-check`).
- Consumer repositories' own `.claude/` bridges and `AGENTS.md` files; they reach
  these skills through pinned Workshop pointers that move only when requested.
