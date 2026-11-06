# Problem lifecycle

Problem records describe existing flaws, their evidence, and their impact.
This guide owns their lifecycle independently of tasks and Kaizen adoption;
local `docs/work/problems/README.md` files add repository-specific conventions.

## Distinguish the artifacts

| Artifact | Records | Completion or retirement |
|---|---|---|
| Kaizen journal entry | An incident or lesson about how work happens | Kaizen evidence-retention review |
| Kaizen pattern | A recurring tendency across incidents | Its lesson is incorporated into a verified standard |
| Problem record | A specific flaw that exists now | The documented flaw is verified gone |
| Task | Work intended to produce a change | Its acceptance criteria and completion requirements are met |

Classify by the claim, not only the subject. A defective development script can
produce both a journal incident and a problem record. A process or instruction
can itself contain a fixable flaw. One incident can establish a problem; a
recurring pattern requires multiple observations. A problem need not originate
in Kaizen and a repository need not adopt Kaizen to maintain problems.

## From observation to retirement

- `problem-create` records the flaw using its canonical template.
- `problem-status` checks current signals; `problem-audit` investigates claims
  and history more deeply. Neither retires records.
- `problem-plan` decides an approach or records acceptance or deferment.
  Tasks own the solution and implementation. Acceptance parks a still-existing
  flaw; deferment and task completion do not establish that it is gone.
- `problem-resolve` verifies the record's observable claims and retires it only
  when the evidence establishes the flaw is gone. `task-implement` invokes it
  during close-out for linked problems the implementation appears to resolve,
  and presents the resulting candidates with the task close-out. Partial fixes and unavailable
  evidence leave the record in place, with the limitations reported.

Use the [bucket definitions](../.agents/skills/problem-create/bucket-definitions.md)
for discovery and placement. Keep the record while its flaw exists, even when
work has been planned or completed. Git preserves retired records; do not keep
fixed problems as evidence archives or add a done bucket.

## Retirement contract

Derive checks from the problem's claims, state their scope and sufficiency
before running them, and preserve all results. A merged task or code that looks
correct is not verification of the outcome. Intermittent claims need a justified
observation plan; repeated clean runs without that justification are insufficient.
The [resolve skill](../.agents/skills/problem-resolve/SKILL.md) owns execution.

Repair editable inbound references and run applicable repository checks in the
same candidate as deletion. Preserve unrelated edits. Flag potentially moot
work instead of silently deleting its task. Issue closure is separately owned;
retiring a document does not close a linked issue.

## Relationship with Kaizen

Kaizen review may discover a flaw and file a problem. That handoff does not
transfer ownership of problem retirement to Kaizen. Conversely, fixing a flaw
does not establish that its incidents have yielded every useful process lesson.

`problem-resolve` preserves journal entries. When a problem cites journal
evidence, it writes a [pending review receipt](kaizen-guide.md#problem-retirement-receipts)
with the retirement, so `kaizen-review` can assess those entries later without
rediscovering the deleted evidence list. No journal evidence means no receipt
and no Kaizen prerequisite. Journal slug citations to retired records survive;
legacy journal links follow the guide's explicit one-time adoption procedure.

## Adopting this boundary

Update local problem guidance that assigns retirement to `kaizen-resolve` or
requires same-commit journal deletion; preserve unrelated local conventions.
Update Kaizen guidance to read pending receipts independently of review windows.
Refresh shared skill links when adopting this Workshop revision. The old command
is a compatibility redirect, not a second implementation.

Existing records and journal entries need no content migration for this ownership
change. Existing legacy-link migration requirements remain applicable. No pinned
consumer changes until its owner explicitly adopts the revision.
