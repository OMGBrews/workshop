---
status: not-started
effort: large
priority: high
dependencies: [reshape-the-definition-of-done-convention]
---

# Add a definition-of-done conformance check

**In brief**: Once every project describes its finish line in the same shape,
something has to confirm that each description is complete, well-formed, and
honest. The only check that exists today asks whether the page exists and has
some words on it. This task builds the real check: it rejects a page that skips a
question or answers with the wrong kind of value, confirms that the commands a
project names actually exist, and refuses to let a project claim a protection the
platform enforces unless the project says how that was observed. It must also
give a plain, truthful answer for every project layout the fleet actually uses,
including the ones it cannot inspect.

## Goal

Add a Workshop tool that validates a repository's `docs/work/definition-of-done.md`
against the reshaped schema, with negative fixtures proving a malformed or
dishonest declaration cannot pass, and wire it into `make check`.

## Context

This is Phase 2 of hq's fleet verification standardization plan
(`docs/planning/fleet-verification-standardization.md` in hq) and depends on the
schema fixed by `reshape-the-definition-of-done-convention`.

Today's bar is clause 6 of `Tools/check-docs-work-conformance.sh`: the file
exists, has a level-one heading, and has at least two non-heading lines
("The file exists" would pass on the shape a half-done rollout leaves behind).
Clause 7 reports a `DOCS-ONLY` block without validating it, because
`Tools/docs-only-diff.sh` owns that syntax. hq's `tests/verify-definition-of-done.sh`
applies the same content bar across the fleet and adds import-mirror and
terminology-delivery assertions, but it too reads nothing inside the document.

The plan sets the checker's obligations:

- Validate **document shape** and **commands derived from, not written beside,
  the artifacts they verify**: a declared local aggregate is a `Makefile`
  target, a script on disk, or a workflow step that exists at HEAD, not prose.
- **Never claim an external GitHub rule exists** unless that state was observed
  authoritatively. A `platform-enforced` declaration must cite how it was
  observed; the checker validates the citation is present, not that GitHub
  agrees today. That live observation belongs to the Phase 6 audit.
- **Accept both shapes during migration** and report them distinguishably —
  transitional versus conformant, the way hq's terminology-delivery check
  reports repositories that have not begun migrating — then lose the old-shape
  path after adoption rather than keeping a permanent allowlist.
- **Accept every sanctioned repository topology or name the unsupported one
  explicitly.** hq's kaizen journal
  (`docs/work/kaizen/journal/2026-08/2026-08-22-generic-docs-conformance-missed-hq-wrapper-path.md`
  in hq) records the generic conformance checker rejecting hq's
  wrapper-mediated template path as a defect when it was an applicability gap;
  an applicability gap misread as a defect is a false red.

The checker must run from a standalone Workshop clone (Workshop's own
`docs/work/definition-of-done.md` says the suite needs no private upstream), and
from a consumer repository through whatever mount it reads Workshop by, since
that is how `Tools/check-docs-work-conformance.sh` is invoked today
(`workshop/Tools/check-docs-work-conformance.sh .`).

Signal hygiene applies to the tool itself: its exit status and complete output
are the verdict, a negative result is a lower bound until the check is shown to
have been able to see a positive, and the negative fixtures are what prove that.

## Scope

- `Tools/check-definition-of-done.sh` (name to be settled at finalize) — the
  new checker.
- `tests/test-check-definition-of-done.sh` and fixtures under `tests/` — one
  conformant fixture per profile, plus negative fixtures for each rejected
  shape.
- `Tools/check-docs-work-conformance.sh` clause 6 — either delegates to the new
  checker or keeps its universal bar with a note that the schema check lives
  elsewhere; decided at finalize, not both.
- `Makefile` — `test` and `lint` targets pick up the new script.
- `docs/definition-of-done.md` — names the checker as the conformance
  requirement's mechanism.

## Acceptance criteria
<!-- AC:BEGIN — DO NOT REMOVE: /task-finalize, /task-move, and the task-queue worker parse the AC list between these sentinels. -->

- [ ] A declaration missing any of the six sections, or using a value outside
      the terminology document's vocabulary for applicability, evidence type,
      enforcement, or evidence state, fails with output naming the section and
      the offending value.
- [ ] A declared command that does not resolve to an artifact at HEAD (a
      `Makefile` target, a script path, or a workflow step) fails, and one that
      does passes; the check reads the artifact, not the prose around it.
- [ ] A `platform-enforced` declaration with no observation citation fails; the
      check never asserts that a GitHub ruleset exists or binds.
- [ ] A truthful content-or-scaffold declaration with `none` and `not applicable`
      answers and no commands passes.
- [ ] An old-shape declaration is reported as transitional, distinguishable in
      output from conformant and from failed, and the removal of that path is
      recorded as a known gap or follow-on task rather than left implicit.
- [ ] Run from a standalone Workshop clone and from a consumer through its
      Workshop mount, the check reaches the same verdict on the same document;
      an unsupported topology is named in the output as unsupported rather than
      reported as a defect.
- [ ] Negative fixtures exist for every rejected shape above and the test suite
      proves each one fails; `make check` passes in a standalone clone.

<!-- AC:END -->

## Stopping conditions

Done when the acceptance criteria hold at HEAD, `make check` exits 0 in a
standalone clone with the new test included, and Workshop's own declaration
passes as conformant. Stop and refine the schema instead if a fixture can only
pass by copying policy, by adding a no-op command, or by a check that reports
green without reading the artifact it claims to verify — the hq plan names those
as phase-boundary stop conditions.

## Open questions

- Does the new checker replace clause 6 of `Tools/check-docs-work-conformance.sh`
  or run beside it? The universal "exists with content" bar has value for
  repositories that have not migrated, and only one tool should own the answer.
- What does the check require as a `platform-enforced` observation citation — a
  dated note, a link to a ruleset page, or an `Unconfirmed` fallback state — and
  how does it keep that from becoming a hand-maintained status claim?
- Which repository topologies are sanctioned for this check to enumerate: a
  root-level `workshop/` checkout, a nested `workshop-dev/workshop/`, a
  `devtools/` mirror, and what else the fleet manifest reveals?

## Out of scope

- Observing live GitHub rulesets or workflow health; the Phase 6 audit owns that.
- The generated fleet matrix (Phase 4).
- Editing any consumer repository's declaration to make it pass.
