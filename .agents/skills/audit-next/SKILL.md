---
name: audit-next
description: Print the next file or directory to audit for a given audit type (code-quality, doc-quality, readme-quality, test-quality, code-test-coverage). Uses the shared audit tracker (via the audit-and-fix skill) to choose based on never-audited → stale → oldest.
---

# Audit Next

Print the next file or directory the user should audit for the given audit type.
Use this for an operator who wants only queue selection, without running the
full review-and-fix workflow.

**Compatibility**: Requires Git, Python 3.11+, and the sibling
`audit-and-fix` skill, which owns the tracker engine.

**Arguments**: `<audit-type> [-n N] [--never|--stale] [--kind file|directory] [--under <path>]`. If no arguments are given, print usage and stop.

## Usage

If no arguments were given, print usage and stop:

> Usage: `audit-next <audit-type> [-n N] [--never|--stale] [--kind file|directory] [--under <path>]`
> Types: `code-quality`, `doc-quality`, `readme-quality`, `test-quality`, `code-test-coverage`
> `--under <path>` restricts candidates to the given repo-relative path and its descendants.
> Example: `audit-next code-quality --kind directory -n 3`
> Example: `audit-next code-quality --under app/features/suggestions -n 5`

## Execute

Run, passing through the arguments the user gave:

```bash
python3 .agents/skills/audit-and-fix/tracker.py next <audit-type> [-n N] [--never|--stale] [--kind file|directory] [--under <path>] --format json
```

Wait for completion and branch on exit status before reading the JSON:

- A non-zero exit is a tracker failure; report stderr and do not call it an empty queue.
- `outcome: not-configured` means the repository has not opted in. Point to the `audit-and-fix` README and do not suggest that there is nothing to audit.
- `outcome: empty` means there are no applicable candidates for these filters.
- `outcome: selected` carries a `candidates` array. Print each candidate's path, kind, and reason in order.

Do not pick the next path yourself — the tracker's ordering is authoritative (never-audited → most-commits-since-audit → oldest-audited).
