# Problem bucket definitions

Problem buckets express how soon a flaw needs attention: investigation,
mitigation, or fix planning. This is the shared authority for problem placement
and discovery; local READMEs provide courtesy summaries and preserve local guidance.

## Planning horizons

| Bucket | Holds |
|---|---|
| `now/` | Flaws requiring attention now |
| `soon/` | Flaws to address after current priorities |
| `later/` | Known flaws with tolerable current impact and no near-term commitment |
| `never/` | Explicitly parked flaws whose continued existence is understood and accepted |

These are attention horizons, not severity or implementation status. A blocked
fix can leave a problem urgent. Problems have no `finalized/`, `queued/`, or
`done/` buckets: related tasks own execution, and `kaizen-resolve` owns retirement
once the flaw is verified gone. A completed task is not proof of resolution.

`problem-reprioritize` moves records among now, soon, and later. Explicit user
direction owns entry to or exit from never; automatic ranking neither parks nor
unparks records. Record the user's parking reason in Background when parking,
or as the record's `**Disposition**: Accepted` line when `problem-plan` parks
it; do not invent acceptance of a risk. Status and audit sweeps include never.

Aim for roughly three now and three soon problems, with later holding the rest.
These are soft attention budgets, not quotas or severity caps. Never demote an
urgent flaw to satisfy a count or promote a low-urgency flaw merely to fill space.
Report deviations. No new frontmatter is required; priority is represented by
location, while the record remains prose about the flaw.

## Discovery and compatibility

The root is `docs/work/problems/`. Readers include immediate Markdown records
at the root (legacy, unbucketed) and in all four named buckets. Exclude README.md,
_TEMPLATE.md, and non-Markdown files. Preserve valid legacy prose without a
heading migration. Do not follow symlinked records or directories outside the
collection, silently omit unknown nested Markdown, or choose between duplicate
slugs. Report these layout errors before applying moves.

Use `list-records.py` beside this document, resolved from the skill's physical
location, with the repository root as its argument. It prints JSON with a
collection state (`absent`, `empty`, or `present`) and records containing
repository-relative `path`, `slug`, and `bucket` (`unbucketed` for root records).
It includes untracked files and exits nonzero for ambiguous or unsupported layouts.
Inspect its exit status; failed discovery is not an empty collection.

New records go in an explicitly requested bucket, otherwise soon. Creation checks
slug collisions across the whole collection. Missing directories may be scaffolded
without replacing local guidance or moving existing records. `problem-reprioritize`
classifies unbucketed records during an authorized rebalance; a dry run writes nothing.
Empty directories may carry `.gitkeep`; guides are never ranking candidates.

## Moving records

A move owns incoming live references and relative links inside the moved record.
Plan the complete old-to-new mapping first, including cross-links between moved
records. Use the shared [link rewriter](../../../Tools/rewrite-moved-markdown-links.sh)
for outgoing rebasing where applicable, then repair destinations using the mapping.
Search the owning repository's tracked and untracked live sources explicitly;
do not assume a search at a gitignored workspace root sees other repositories.
Report known external references without editing other repositories implicitly.

Immutable journal entries stay unchanged. Report historical citations to moved
paths and run the repository's required link check under its existing policy.
If historical links block adoption, report the blocker; do not weaken the check,
rewrite journal history, or add duplicate problem records as redirects.

Stage only the intended moves and link edits, preserving unrelated work. Never
overwrite a destination, merge duplicate slugs, or delete a record during ranking.
