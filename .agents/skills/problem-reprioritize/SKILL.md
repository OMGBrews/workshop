---
name: problem-reprioritize
description: Rebalance problem records into attention-horizon buckets in one decide-then-apply pass, including migration of legacy flat collections. Supports a read-only dry run; does not retire problems or reprioritize tasks.
---

# Reprioritize problems

Rank documented flaws by the cost of leaving them unresolved, then stage bucket
moves and their necessary link repairs. Print the whole plan before applying it;
do not ask for per-record confirmation. Never commit or push automatically.

Use this for a requested problem rebalance, not an ordinary status inquiry.
Arguments may narrow the repository or request a dry run. Scope is one repository;
fleet adoption is separate. A dry run performs no writes or staging.

## Read the contracts and inventory

Resolve this skill's physical directory before reading siblings, following
[skill path resolution](../../../docs/skill-path-resolution.md). Read
[problem bucket definitions](../problem-create/bucket-definitions.md), the local
`docs/work/problems/README.md`, and [ranking-rubric.md](ranking-rubric.md).
Report the paths used. Local guidance is preserved; report conflicting placement
policy before mutation rather than silently replacing it.

Run `python3 <physical-problem-create-dir>/list-records.py <repo-root>` and inspect
its exit status and JSON. An absent or empty collection is a reported no-op, not
proof that the repository has no flaws. An inventory error stops the pass.

Read every record in full, including parked records as context. Extract title,
flaw, impact, recurrence, reach, mitigation, evidence limitations, and linked
work. Accept legacy prose. Do not manufacture task status, progress, or effort
fields. Related tasks are read-only context, never candidates for moves.

Read `docs/work/tasks/focus.md` under the shared [focus contract](../../../docs/focus-document.md) if it exists; do not create a problems-specific
focus. Check existence before consulting git. Report absent, uncommitted
(staleness unknown), current, or older than roughly 30 days (use it but flag
possible staleness). A focus match requires a quoted passage covering the flaw;
missing focus leaves impact-based ranking fully usable.

Use relevant problem-status or problem-audit findings already available in the
conversation, identifying their basis and limitations. This pass is document-led,
not a fresh audit or reproduction. Clearly separate documented impact from verified
current evidence. Flag stale premises for problem-audit; uncertain high-impact
claims may warrant immediate investigation rather than automatic demotion.

## Decide once

Rank root-level, now, soon, and later records with the rubric. Never automatically
move a never record. Classify legacy root records into the same horizons; do not
bulk-file all legacy records into the default creation bucket.

Print a compact inventory and diagnosis: counts, focus state, urgent exposure,
mitigations, evidence uncertainty, linked work, and exceptions to the soft targets.
Then print the complete proposed mapping:

| Problem | From | To | Reason | Evidence basis | Focus |
|---|---|---|---|---|---|
| title / slug | unbucketed or bucket | bucket | concrete cost of delay | documented / audit finding / uncertain | quoted passage or none |

Include unchanged records in a concise explanation when their urgency, parking,
or uncertainty matters. Name how many moves focus actually decided. Likely-fixed
records stay at their existing location pending kaizen-resolve; for an unbucketed
one, report migration deferred rather than inventing an urgency assessment. No
record is deleted because a related task completed or an audit suspects a fix.

## Apply and verify

For dry run, stop after reporting the plan, resulting counts, and link-repair
requirements. For an empty plan, report no moves; do not stage unrelated changes.

Before mutation, inspect git status and preflight the full mapping for collisions,
changed sources, live references, and historical citations. Preserve pre-existing
edits and staging: if a required edit overlaps unrelated changes, leave that
record unmoved and explain the conflict. Create only missing bucket directories
needed for adoption, preserving README content and adding a canonical-definition
pointer if absent. Do not rewrite records except necessary links.

Follow the bucket contract's moving-record rules. Use `git mv` for tracked sources;
move untracked sources without overwriting and stage their destinations explicitly.
Repair incoming live links and outgoing relative links, including links between
moved records. Leave immutable journal entries unchanged and report their paths.
Stage only intended moves and repairs; never use blanket `git add .`.

Run inventory again: require the same slug set and count, exactly the planned
placements, no root records except explicitly deferred ones, and unchanged parked
placements. Inspect the diff for prose changes beyond links and intended guidance.
Run the repository's applicable checks, including links after staging new paths.
Re-evaluate ranking against the same evidence to ensure another pass proposes no
churn; do not run a second mutation pass to force the result into shape.

Report before/after counts, each move's reason, focus contribution, historical
citations, deferred records, evidence limitations, check outcomes, and next owners
(problem-audit for re-verification; kaizen-resolve for possible retirement).
State that changes are staged and uncommitted. Failed or unavailable required
checks leave adoption incomplete; name the blocker without weakening policy.
