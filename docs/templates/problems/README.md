# Problems

This directory documents currently-existing flaws in this project — defects in what it builds or runs (code, tooling, infrastructure, records) that affect it today. Read these documents when investigating an issue, scoping work to address a flaw, or building context before proposing a fix.

A problem document describes the *state of the world*: what is wrong, where it manifests, and what it costs. It does not prescribe a solution or acceptance criteria — those belong in a task once someone is ready to act.

This README was seeded from the mounted Workshop tree's `docs/templates/problems/README.md` — the copy is this repo's own to edit (a seed, not a mirror; deliberate divergence is fine). The concept and lifecycle were proven in `foiassist/pia-maker`'s `docs/problems/` before being adopted fleet-wide (2026-08-05).

## When to add a document

Create a problem document when:

- A flaw is real and reproducible today, but no task is yet scoped to fix it
- The flaw needs background or evidence that would clutter a future task document
- Multiple potential fixes exist and the choice is not yet made
- The flaw is structural enough that you want it discoverable independent of any specific work item

Do not create a problem document for:

- **Concrete, ready-to-execute work** → the repo's tasks directory (`docs/work/tasks/`)
- **An incident or lesson about how we work** → `docs/work/kaizen/journal/`; recurring tendencies belong in `docs/work/kaizen/patterns/`. A specific defect in tooling, process, or instructions still belongs here when its continued existence and eventual removal can be verified. The incident and the defect may each warrant a record.
- **Speculative future features** → the repo's planning/ideas area

## Priority buckets

Problems are grouped by attention horizon: `now/` needs attention now, `soon/`
is next, `later/` tolerates deferral, and `parked/` is explicitly parked.
The authority for placement, discovery, and moves is
`.agents/skills/problem-create/bucket-definitions.md` (resolved from the repository
root). These are courtesy summaries, not separate bucket definitions.

`problem-reprioritize` stages moves and link repairs in one pass, or reports a
read-only dry run. It ranks the cost of delay, uses the existing task focus, and
never retires records. Status and audit include parked and legacy root records.
New records default to soon unless a bucket is requested. Problems carry no
execution buckets; related tasks own implementation.

## Lifecycle

The canonical [problem lifecycle](../../problem-lifecycle.md) owns creation,
planning, and retirement independently of Kaizen adoption. When seeding this
README into a consumer, rewrite that link to its mounted Workshop guide.

A problem persists while its flaw exists. `problem-resolve` verifies the actual
outcome before retiring it; task completion alone is not evidence. Acceptance
and deferment retain an existing flaw. Git preserves retired records.
Repair editable inbound references in the same change and run applicable checks.

Journal entries are preserved during problem retirement. If the problem cites
journal evidence, `problem-resolve` writes a pending review receipt with the
deletion; `kaizen-review` later decides retention. Journal slug citations survive
unchanged, and legacy journal links require the guide's one-time adoption before
retirement. A problem without journal involvement requires no Kaizen files.

A single problem may spawn several tasks. Tasks carry solutions and cite the
problem; the problem does not restate their acceptance criteria.

## Document structure

Name the file `kebab-case.md` after the flaw (e.g. `export-drops-step-3-narratives.md`) — no date prefix, since a problem persists until its flaw is fixed.

The canonical shape lives at `.agents/skills/problem-create/_TEMPLATE.md`: an In brief paragraph followed by Scope statement, The flaw, Evidence, Impact, Background, and See also. This is a courtesy summary; the template is the single source. Avoid prescribing solutions. If a fix approach is obvious, mention it briefly under See also or leave it for a task document.

### Linking GitHub issues

Optionally add an `**Issues**:` body line directly after the In brief paragraph
(after the title in a legacy document without In brief), before any Disposition
line.
It is never a frontmatter field. Omit it when there are no linked issues.

```markdown
**Issues**: [#175](https://github.com/owner/repo/issues/175) Issue title · [#176](https://github.com/owner/repo/issues/176) Another issue title
```

Use full URLs, the issue number as link text, then the issue title. Separate
issues with ` · `. A short parenthetical after a title may clarify the
relationship, such as `(related symptom)`.

Issues and documents have independent lifecycles. Deleting a document deletes
its link; it never implies closing the issue. Closing an issue remains a
separate human step. The shared Markdown link checker skips external URLs,
so it does not verify these links or issue status.

### The Disposition line

A record the user has decided to live with carries one line recording that decision, directly after the `**In brief**:` paragraph (after an `**Issues**:` line where this repository uses one). It is a body line, never a frontmatter field, and it starts with one of two fixed prefixes so a sweep can find it:

```markdown
**Disposition**: Accepted YYYY-MM-DD. <One sentence: why living with it beats fixing it.>
**Disposition**: Deferred YYYY-MM-DD until <condition>. <One sentence.>
```

`problem-plan` writes it, replaces it on a revisit, and stops on a record that already carries one. An Accepted record is parked in `parked/`, and the line is its parking reason. A record planned into a task carries no Disposition line: the task citing the record is the mark. A record with neither has not been decided yet.

Skills: `problem-create` files a record from the canonical template, `problem-status` reports current signals, `problem-audit` re-verifies the record in depth, `problem-plan` decides what to do about it, and `problem-resolve` retires it only after the flaw is verified gone.

## See also

- The repo's tasks directory — concrete, actionable work items
- `docs/work/kaizen/` — friction in how we build, and the recurring tendencies distilled from it
- The mounted Workshop tree's `docs/kaizen-guide.md` — the Act-stage routing that sends flaw-shaped clusters here instead of into `patterns/`
