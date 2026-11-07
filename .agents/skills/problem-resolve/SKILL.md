---
name: problem-resolve
description: Verify that a documented problem is gone, then retire its record and repair references. Preserves Kaizen journal evidence and hands its retention review to kaizen-review. Use for a named fixed or likely-fixed problem, independently of task completion or Kaizen adoption.
---

# Resolve a problem

Retire one verified-fixed record from `docs/work/problems/`. This skill owns
problem retirement; it never deletes journal entries or graduates patterns.
It stages the candidate for review, without committing or pushing.

**Arguments:** a problem slug or path. Without one, list the inventory and ask
which record to inspect; never pick a retirement candidate implicitly.

## Phase 1 — Resolve the record and policy

Resolve this skill's physical directory before following relative paths
([path rule](../../../docs/skill-path-resolution.md)). Read
[problem lifecycle](../../../docs/problem-lifecycle.md) and the repository's
`docs/work/problems/README.md` if present. A missing shared guide requires the
complete distribution; do not substitute the Kaizen guide. Report conflicting
local retirement rules before staging, rather than silently overriding them.
Kaizen adoption is not a prerequisite.

Run `python3 <physical-problem-create-dir>/list-records.py <repo-root>` using
[the inventory helper](../problem-create/list-records.py); inspect its exit
status. Stop on inventory errors, distinguish absent and empty collections,
and resolve exactly one record, including bucketed and legacy paths.
Read the whole record and snapshot its status and diff. Preserve pre-existing
edits; if retirement would discard them, resolve that conflict before staging.

## Phase 2 — Define the claim and its dependencies

Extract the load-bearing observable claims, evidence sources, and linked work.
Search explicit repository paths for inbound references, including untracked
live documents. Distinguish editable references from historical journal slug
citations. Identify every journal entry cited as evidence, including prose
citations, and resolve its actual path without guessing.

Only when journal citations or evidence are present, read the Kaizen guide's
[Journal citations and one-time adoption](../../../docs/kaizen-guide.md#journal-citations-and-one-time-adoption)
and [problem retirement receipts](../../../docs/kaizen-guide.md#problem-retirement-receipts).
Legacy journal links need the separately recorded adoption before retirement;
slug citations survive unchanged. A problem with no journal involvement needs
no Kaizen files or cleanup receipt.

## Phase 3 — The evidence gate

Derive, from the document's own description, what the world looks like while the flaw exists — then design a check that distinguishes *fixed* from *unfixed*, and state it before running it.

- **Not evidence:** the fix task merged or was deleted; a commit whose message claims the fix; a doc or changelog saying it is fixed; the code "looking right" on a skim. All of these are true in the world where the fix silently failed.
- **Evidence:** the reproduction the document describes no longer reproduces; the gate the document says is missing now exists *and names a deliberate mutation when you feed it one*; the state the document says is wrong (a config value, a dangling reference, a duplicated body) can no longer be found by the same search that used to find it.
- **Apply `signal-hygiene.md`'s question**: what would this check print if the fix never happened? If the answer matches success, the check is decorative — design another. This is the step most tempting to shortcut when a fix "obviously" landed, and it is the entire reason this skill exists as a gate rather than a deletion convenience.

Before executing any checks, enumerate **every observable** and classify its evidence:

- **Deterministic** — state the exact input or case, expected result, and coverage of the problem's claim. A pure function or a passing example establishes only its tested cases; justify broader coverage separately.
- **Sampled or intermittent** — state a case-specific observation plan **before viewing results**: planned count, conditions and inputs, detection rationale tied to available reproduction evidence, assumptions about independence and comparable conditions, and limits of the conclusion. Explain why this plan can detect the original flaw and why clean results would be sufficient for this claim. Historical clean or failing draws alone do not establish a reliable failure probability. There is no universal minimum or mandatory statistical formula.

Record all observations, including failures and incomplete runs. Do not retry until clean, discard early failures, or revise the plan after seeing results to obtain a pass. Any deviation must be reported; it cannot erase a reproduction. If a new plan is needed, explain it and its justification before further observations, retaining the earlier results. Technically being able to run more checks does not supply a missing sufficiency rationale.

Three outcomes:

- **Verified gone** — every observable is covered by justified evidence gathered in this session, with output you can quote. Deterministic conclusions stay within the established cases and coverage; sampled conclusions state their justified scope and limitations. No observable reproduced and no evidence justification is missing. Proceed to Phase 4.
- **Cannot verify here** — the evidence needs something this session lacks (a deploy, a rebuild, host access, production data), or the observation plan lacks a defensible sufficiency rationale even if more checks could run. Clean samples with insufficient justification belong here. **Stop.** Report a dry run: the checks that would settle it, what evidence or justification is missing, and where or how it could be obtained. The document stays; nothing is staged. A dry run is a correct outcome, not a failure of the skill.
- **Partially gone** — one or more observables reproduce (including a mixture of fixed deterministic cases and a reproduced intermittent flaw). Any reproduction prevents retirement, regardless of later clean draws or other missing evidence. Stop and say exactly which observables still reproduce. The document persists while any of its flaw exists; if the fixed part deserves recording, editing the document to narrow it is the human's call, not this skill's.

---

## Phase 4 — Prepare retirement and the evidence handoff

Only proceed after every observable is verified gone. Repair editable inbound
references in the same candidate: remove index rows, repoint useful context to
its current source, and flag potentially moot tasks without deleting them.
Never edit surviving journal entries or remove them as part of this operation.

If the problem cites journal evidence, write a pending receipt under
`docs/work/kaizen/pending-problem-reviews/` using the Kaizen guide's receipt
contract. Capture the evidence list **before** deleting the problem, and stage
the receipt with the deletion. It records provenance, not a retention decision.
Missing evidence or an unresolved receipt collision stops preparation; do not
silently omit an entry. Do not create Kaizen directories for a problem without
journal evidence.

Stage only this run's problem deletion, editable reference repairs, and receipt,
by explicit paths. Preserve unrelated index and working-tree changes. The
receipt and retirement must land together; neither depends on a Kaizen review
having run. Read the staged diff to confirm journals are unchanged.

## Phase 5 — Check and report

Run the repository's applicable definition-of-done checks, including its
whole-tree link check. A failed check leaves the candidate unready; do not
weaken it or rewrite immutable history to obtain a pass. Recheck inbound
references and inspect the actual staged paths.

Report the record, evidence plan and every result, scope and limitations of the
conclusion, repaired references, surviving journal citations, receipt path (or
no journal evidence), and check outcomes. State that journal retention awaits
`kaizen-review` when a receipt exists. If verification was unavailable or any
observable reproduced, report a dry run and leave retirement unstaged.

Do not commit or push. Suggest `docs(problems): retire <slug> — flaw verified gone`.
Git preserves the retired record; do not create an archive copy.

## See also

- [Reader fixture](../../../docs/problem-resolve-reader-fixture.md) — controlled
  evidence and ownership trials; a written protocol is not an executed trial.
