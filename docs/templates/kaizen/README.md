# Kaizen

This project's continuous-improvement system: a log of friction in **how we build** (the collaboration loops between humans, AI agents, and tooling) and the recurring patterns distilled from it. Read this to learn from past friction or to contribute your own observations.

The methodology — what kaizen is, when to write an entry, the PDCA cycle, the entry/pattern formats, and how patterns graduate into rules — is shared across every project that adopts this system and lives in one place:

**→ `<workshop-root>/docs/kaizen-guide.md`** (canonical guide)

`<workshop-root>` is the name this project mounts the shared tools tree by (the `kaizen-init` skill substitutes the real name when it copies this template).

## What's in this directory

| Path | Description |
|------|-------------|
| [journal/](./journal/) | Running log of friction, errors, and lessons — one entry per file, at `YYYY-MM/YYYY-MM-DD-<slug>.md` |
| [patterns/](./patterns/) | Recurring themes distilled from the journal, with mitigations and status — one pattern per file |

There is no index file. `ls` is the index, and `grep -h '^# ' journal/*/*.md` lists every entry title.

Problem retirement preserves journal evidence. Receipts under
`pending-problem-reviews/` (created only when needed) hand that evidence to
`kaizen-review`, which reads them regardless of its review window and decides
retention under the guide. Problem records have their own lifecycle.

## Scope reminder

Kaizen is about the **way** we work, not the **thing** we build. Process friction (a worker raced a commit, a hook fired too late, an instruction was misread) goes in the journal. A journal records the incident; a specific, continuing flaw in that process or tooling belongs in a problem record. Feature ideas and product gaps belong wherever this project tracks future work.

## Quick links

- The `/session-end` skill captures this session's unrecorded friction into [journal/](./journal/) before context evaporates.
- Run a [patterns/](./patterns/) review every ~2 weeks or after a sprint (see
  the canonical guide at `<workshop-root>/docs/kaizen-guide.md`).
