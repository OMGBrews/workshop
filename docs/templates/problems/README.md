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
- **Friction in how we build** — collaboration loops between humans, AI agents, and tooling → `docs/work/kaizen/journal/`; recurring *tendencies* distilled from it → `docs/work/kaizen/patterns/`. A problem tracks a fixable *state*; a pattern tracks a *tendency*. The discriminator is whether "verified gone" is a meaningful endpoint.
- **Speculative future features** → the repo's planning/ideas area

## Lifecycle

A problem document persists while the flaw exists. Delete it once the flaw is verified gone — usually after a task fixes it, but **task completion alone is not the trigger**: verify the flaw is gone first, from the world's side, then delete. Git preserves the history.

**Deleting the document deletes the journal entries it consumed.** A problem filed from a kaizen cluster cites `docs/work/kaizen/journal/` entries as evidence; those entries are *consumed* by it, and the same commit that deletes the document deletes them — provided nothing else live still cites them. Check each one before removing it:

```bash
grep -rn "<entry-filename-without-.md>" --exclude-dir=.git docs/      # linked citations
grep -rn "<a distinctive phrase from the entry's title>" --exclude-dir=.git docs/   # prose ones
```

Any hit from something live — a pattern, another problem, a task, a CLAUDE.md, or another journal entry — and the entry stays. The rule, the reasoning, and the second grep's necessity are in the mounted Workshop tree's `docs/kaizen-guide.md` under *The journal's lifecycle*.

The cascade belongs to **the session that verifies the flaw gone**, because that session is the only one holding the document's evidence list — once the file is deleted, nothing records which entries it absorbed. `/kaizen-resolve` is that session's ritual — run it rather than reconstructing this by hand. Skipping it costs one stray entry rather than a broken link, but that entry then matches nothing and is read by every future review.

A single problem may spawn one task or several. Tasks reference back to the problem document for context; the problem does not restate their acceptance criteria.

## Document structure

Name the file `kebab-case.md` after the flaw (e.g. `export-drops-step-3-narratives.md`) — no date prefix, since a problem persists until its flaw is fixed.

The canonical shape lives at `.agents/skills/problem-create/_TEMPLATE.md`: an In brief paragraph followed by Scope statement, The flaw, Evidence, Impact, Background, and See also. This is a courtesy summary; the template is the single source. Avoid prescribing solutions. If a fix approach is obvious, mention it briefly under See also or leave it for a task document.

Skills: `problem-create` files a record from the canonical template, `problem-status` reports current signals, `problem-audit` re-verifies the record in depth, and `kaizen-resolve` retires it only after the flaw is verified gone.

## See also

- The repo's tasks directory — concrete, actionable work items
- `docs/work/kaizen/` — friction in how we build, and the recurring tendencies distilled from it
- The mounted Workshop tree's `docs/kaizen-guide.md` — the Act-stage routing that sends flaw-shaped clusters here instead of into `patterns/`
