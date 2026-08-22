---
name: audit-done
description: Mark a file or directory as audited for a given audit type. Records the current git HEAD so future runs can detect staleness.
allowed-tools: Bash
---

# Audit Done

Mark the given path as audited for the given audit type at the current git HEAD.

**Arguments**: `<path> <audit-type> [--note "..."]` — at least the path and the audit type are required.

## Usage

If fewer than two arguments were given, print usage and stop:

> Usage: `audit-done <path> <audit-type> [--note "..."]`
> Types: `code-quality`, `doc-quality`, `readme-quality`, `test-quality`, `code-test-coverage`
> Example: `audit-done app/features/suggestions/engine.py code-quality`

## Execute

Run, passing through the arguments the user gave:

```
python3 .agents/skills/audit-and-fix/tracker.py done <path> <audit-type> [--note "..."]
```

Report the tracker's response. If it prints "not applicable", the path either isn't covered by the audit type's config rules or hasn't been discovered yet — suggest:

```
python3 .agents/skills/audit-and-fix/tracker.py refresh
```

Remind the user to commit the updated `docs/work/audits/records/<audit-type>.json` so the record is shared. If the tracker exits with a "not opted in" message, this repo has no `docs/work/audits/config.toml` — see the `audit-and-fix` skill README for the opt-in.
