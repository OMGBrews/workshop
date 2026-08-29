---
name: focus-update
description: Write, rewrite, trim, or replace a repository's focus document. Use for explicit focus-document updates, not ordinary task selection, reprioritization, implementation, or session landing.
---

# Update Focus

Write `<tasks>/focus.md` to the single artifact contract in
[`docs/focus-document.md`](../../../docs/focus-document.md). Resolve `<tasks>` as
`docs/work/tasks/`; if that directory is absent, report that this repository has not
adopted the task system and stop.

## Direction comes from the owner

Use direction the owner states in the request. If the request does not state it, read
the existing focus document for context, then ask what the repository should concentrate
on now and what, if anything, is deliberately not now. Never derive either answer from
the queue, task metadata, recent commits, or your own ranking judgment.

An existing document is evidence of the owner's stated direction, not permission to
invent a different one. When trimming a nonconforming document, preserve that direction
and confirm any materially ambiguous interpretation before writing.

## Replace to the contract

Read the contract completely, then create or replace the file in place. Never append to
an existing focus document and never preserve a history section: an over-length,
task-linking, dated, or otherwise nonconforming document receives a conforming
replacement.

Keep the result directional and at most 15 lines. Do not write a next-action pointer,
including prose such as “start with X.” Put any permitted plain-text task references
only on the optional, single, unwrapped `**Not now:**` line. Never link to task briefs.

Route substance displaced by the rewrite according to the contract: quality bars and
rationale belong in a planning document; task-shaped work belongs in task briefs. Reuse
an appropriate existing document when one owns the material. Creating or materially
expanding those destinations is part of the requested focus rewrite, but do not silently
turn undecided prose into committed work: ask when the routing requires a product or
priority decision.

## Verify

Read the finished file and positively confirm:

- it has an H1 and no more than 15 source lines;
- its body is owner-stated direction, not a task pointer;
- it contains no date, rationale essay, changelog, or Markdown link into a task bucket;
- it has zero or one `**Not now:**` line, and any task names occur only there;
- displaced material is retained in the appropriate owning documents.

Run the repository's focus-document conformance check when its Workshop pin supplies
the extended clause 9. Otherwise report the manual checks rather than claiming the old
presence-only clause verified the new contract.
