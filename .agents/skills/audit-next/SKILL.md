---
name: audit-next
description: Print the next file or directory to audit for a given audit type (code-quality, doc-quality, readme-quality, test-quality, code-test-coverage). Uses the shared audit tracker (via the audit-and-fix skill) to choose based on never-audited → stale → oldest.
allowed-tools: Bash
---

# Audit Next

Print the next file or directory the user should audit for the given audit type.

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

```
python3 .agents/skills/audit-and-fix/tracker.py next <audit-type> [-n N] [--never|--stale] [--kind file|directory] [--under <path>]
```

Show the raw output to the user. Each line is `<path>\t[<kind>]\t<reason>`. If the result is empty, the tracker had no applicable paths — suggest refreshing it via:

```
python3 .agents/skills/audit-and-fix/tracker.py refresh
```

Do not pick the next path yourself — the tracker's ordering is authoritative (never-audited → most-commits-since-audit → oldest-audited).
