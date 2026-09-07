---
status: not-started
effort: medium
priority: high
dependencies: []
---

# Reshape the definition-of-done convention

**In brief**: Every project in the fleet keeps one page saying what proof is
needed before its work counts as finished. Today those pages are free-form: each
one lists a few commands in a table, and none of them says what kind of project
it is, how changes are allowed to land, whether anything actually blocks a bad
change, or what happens at release and deployment time. This task rewrites the
shared rulebook for that page so every project answers the same questions in the
same order, keeps "we have none" as an honest answer, and stops passing off a
hoped-for protection as a real one.

## Goal

Rewrite `docs/definition-of-done.md` and add a canonical template so that every
repository's `docs/work/definition-of-done.md` declares its profile, landing
route, and enforcement level, then answers pre-commit feedback, landing, release,
deployment, and known gaps in that order, with the terminology document's axes
kept distinct instead of flattened into one field.

## Context

This is Phase 2 of hq's fleet verification standardization plan
(`docs/planning/fleet-verification-standardization.md` in hq). The prerequisite
and Phases 0 and 1 are complete: `docs/verification-terminology.md` owns the
vocabulary and lifecycle, and `docs/verification-profiles.md` (landed in
`91ea89e`) owns the four profiles. This task must not restate either document;
it links to them and consumes their terms.

Today's convention, `docs/definition-of-done.md`, asks for one file in which
"each check names its command, pass condition, applicability surface, and
current enforcement", and repositories answer with one evidence table (see
Workshop's own `docs/work/definition-of-done.md`, or hq's, whose table has the
columns `Requirement | Command | Pass condition | Applies to`). Nothing in that
shape records the repository's profile, its default landing route, whether a
landing requirement is advisory, procedural, or platform-enforced, or what the
release and deployment stages require. The `DOCS-ONLY` block owned by
`Tools/docs-only-diff.sh` lives between sentinels somewhere in the same file
with no defined position.

The plan fixes the six questions, in order:

1. **Repository profile** — profile, default landing route, enforcement level.
2. **Pre-commit feedback** — optional fast checks or hooks, identified as
   feedback rather than the landing decision. A hook is per-clone state no
   committed file can vouch for, so it is declared as a precondition, never as
   a committed execution path.
3. **Landing requirements** — automated and manual evidence required before an
   authorized change reaches the default branch, including the canonical local
   command and the corresponding CI status where one exists.
4. **Release requirements** — evidence required to create or publish an exact
   release candidate.
5. **Deployment requirements** — authorization, promotion, and health evidence
   required to enter an environment.
6. **Known gaps** — missing, advisory-only, unavailable, or unconfirmed
   protections, linked to focused tasks where remediation is planned.

Four axes stay separate: applicability (`none`, `not applicable`), evidence type
(automated or manual), enforcement (`advisory`, `procedural`,
`platform-enforced`), and evidence state (`unavailable`, `unconfirmed`). The
schema must never let enforcement be inferred from the presence of a workflow.
Where a declaration's trustworthiness depends on a precondition — an installed
hook, an initialized checkout, a fresh clone — the precondition belongs inside
the check's verdict, not beside it in prose; a green result with a footnote is
read as green.

hq's provisional profile survey
(`docs/planning/fleet-verification-profile-survey.md` in hq) added four
requirements the schema must meet:

- The **declared unit** must be unambiguous. Coordination roots such as
  `plunk` or `captains-log` are content-or-scaffold repositories that compose
  executable components; a root must not inherit a component's deployment
  obligations, and a component must not lean on its root's declaration.
- The **production profile rests on current deployment ownership or
  evidence**, never inferred from a web stack, a workflow, or deployment
  scripts (`pia-maker` and `found-in-words-cms` are the cases that separate
  the two).
- A **strengthened requirement for a concrete risk** — `health`'s sensitive
  local data is the example — needs a home that does not relabel the
  repository into a profile whose lifecycle stages it does not have.
- During migration, fleet tooling reads **both the old table shape and the new
  shape**; compatibility is removed after adoption rather than kept as a
  permanent allowlist, so the convention must say how a reader tells the two
  apart.

Templates live in `docs/templates/` (`adr.md`, `kaizen/`, `problems/`, and
others); there is no definition-of-done template today. The two sibling
follow-on briefs, `add-a-definition-of-done-conformance-check` and
`point-shared-guidance-at-the-definition-of-done-schema`, depend on the shape
this task fixes.

## Scope

- `docs/definition-of-done.md` — the convention, rewritten around the six
  questions and four axes.
- `docs/templates/` — a new canonical definition-of-done template, with the
  `DOCS-ONLY` block given a defined position.
- `docs/verification-terminology.md` and `docs/verification-profiles.md` —
  link targets only; edit them only to add a `See also` entry.
- `docs/work/definition-of-done.md` — Workshop's own declaration, migrated to
  the new shape as the first worked example, in a form that stays truthful about
  its confirmed ruleset on `main`.

## Acceptance criteria
<!-- AC:BEGIN — DO NOT REMOVE: /task-finalize, /task-move, and the task-queue worker parse the AC list between these sentinels. -->

- [ ] The convention requires the six sections in the plan's order and defines
      each one's contents, and the canonical template in `docs/templates/`
      carries the same six sections with the `DOCS-ONLY` block in a defined
      position that `Tools/docs-only-diff.sh` still finds.
- [ ] Applicability, evidence type, enforcement, and evidence state are
      declared as separate fields with the terminology document's values, and
      the convention states that a workflow's presence never implies an
      enforcement level.
- [ ] A hook or other per-clone precondition can only be declared as a
      precondition inside the check's verdict, and the convention says why a
      footnote beside a green result is not acceptable.
- [ ] The declared unit is explicit, so a coordination root and the components
      it composes each carry their own declaration without inheritance in either
      direction.
- [ ] The production profile requires current deployment ownership or evidence
      to be named, and a strengthened requirement for a concrete risk has a
      stated place that does not change the repository's profile.
- [ ] A content-or-scaffold repository can conform in a few truthful lines, with
      `none` or `not applicable` answers and no invented commands, and the
      template shows that shape.
- [ ] The convention states how a reader distinguishes the old table shape from
      the new shape during migration and that the compatibility ends after
      adoption; it copies no glossary, lifecycle diagram, or profile table from
      the terminology or profiles documents.
- [ ] Workshop's own `docs/work/definition-of-done.md` follows the new shape and
      remains truthful about its ruleset, landing route, and `make check`.
- [ ] `make check` passes in a standalone clone.

<!-- AC:END -->

## Stopping conditions

Done when the acceptance criteria above hold at HEAD, `make check` exits 0 in a
standalone clone, and a reader following only the convention and template can
write a truthful declaration for a low-ceremony repository and for a deployed
one without opening the plan. Do not begin migrating any other repository;
Phase 3 pilots own that.

## Open questions

- Is the declaration a set of headed Markdown sections with small per-section
  tables, or a machine-readable block (front matter or a sentinel-delimited
  block) that the conformance checker parses directly? The checker brief
  depends on this answer, and the answer must keep the file readable by a person
  first.
- Where does the `DOCS-ONLY` block sit in the new shape — inside "Landing
  requirements", as its applicability sub-declaration, or as its own trailing
  block?
- Does the template ship one file with commented guidance, in the style of the
  task template, or a bare skeleton plus a worked example per profile?

## Out of scope

- The conformance checker and its fixtures
  (`add-a-definition-of-done-conformance-check`).
- Repairing the task, task-queue, and shipping guidance that cite the file
  (`point-shared-guidance-at-the-definition-of-done-schema`).
- Migrating any repository other than Workshop itself; the Phase 3 pilot set is
  fixed in the hq plan.
- Any change to the meaning of a term or profile; those belong in their own
  documents through their own change process.
