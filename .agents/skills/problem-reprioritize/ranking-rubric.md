# Ranking problems by attention horizon

Use this rubric to assign attention to documented flaws, not to estimate or
schedule their fixes. Keep evidence confidence separate from urgency and explain
judgment in terms of the concrete cost of delay.

## Ordering and placement

Consider factors in this order, using the record's evidence rather than invented
numeric scores:

1. Immediate harm or time-sensitive exposure: ongoing loss, serious disruption,
   or an approaching consequence requires now, regardless of focus or capacity.
2. Impact and recurrence: repeated failures and accumulating cost outrank isolated,
   low-impact inconvenience when their exposure is otherwise comparable.
3. Reach and blocking effect: multiple affected workflows or an impediment to
   current commitments increase urgency.
4. Demonstrated mitigation: an effective workaround can make delay tolerable;
   an assumed workaround cannot. Include the cost and limits of using it.
5. Focus: among comparable cases, a quoted project-focus passage raises attention;
   an explicit Not now passage lowers it only when delay remains tolerable.
6. Stability: for otherwise comparable records retain current placement, then
   prefer older creation history (follow renames), then slug alphabetically.
   Missing history is unknown, not evidence of age or recentness; use slug when
   history cannot distinguish candidates.

Assign now when attention should start now, soon when the next available capacity
is appropriate, and later when documented impact tolerates unscheduled deferral.
Use roughly three now and three soon as a pressure signal, not a filling algorithm.
If five flaws need attention now, report five and the capacity conflict. If only
one merits now, leave one. Never promote a low-impact item merely to fill a slot.
Explicit user placement instructions take precedence; disclose tension with the
rubric rather than silently overriding the instruction.

## Signals that are not task readiness

- A blocked fix may still need investigation, mitigation, escalation, or monitoring
  now. Report the dependency; do not apply task-reprioritize's blocked demotion.
- A large foundational fix is not a reason to defer a harmful problem.
- In-progress or queued tasks provide context, not automatic promotion, demotion,
  pinning, or evidence that harm has stopped.
- A completed task does not resolve a problem. A supported likely-fixed finding
  routes to kaizen-resolve; leave the record in place pending that workflow.
- Rotten or uncertain evidence is not low severity. Rank the need to investigate
  the claimed impact and state the uncertainty. Do not call an old claim current
  merely because nobody has disproved it.
- Parked records remain visible to status and audit. Automatic reprioritization
  reports newly concerning parked claims but never unparks them on its own.

## Behavioral examples

Use these cases to review the workflow against realistic records. The intended
observable is placement and preserved evidence, not matching explanatory wording.

| Situation | Expected behavior |
|---|---|
| Five currently harmful flaws, all outside focus | All five can remain now; disclose overload, no quota demotions |
| Severe loss claim with missing reproduction evidence | Prioritize investigation if delay is consequential; label uncertainty |
| Urgent flaw whose fix depends on another team | Keep attention now if harm remains; explain dependency |
| Low-impact inconvenience with a reliable workaround | Later may be appropriate even when now has open capacity |
| Related task merged, no world-side verification | Preserve problem; task completion alone cannot retire or demote it |
| Audit reports likely fixed | Leave location unchanged; route to kaizen-resolve |
| Two otherwise comparable flaws, one directly in focus | Focus may determine which receives earlier attention; cite it |
| Never contains a newly concerning flaw | Report it and the need for an explicit placement decision; no automatic move |
| Mixed root, bucketed, parked, and legacy prose records | Inventory all once; classify root candidates individually |
| Second run with identical evidence and focus | No moves caused solely by filling counts or rotating tied records |
