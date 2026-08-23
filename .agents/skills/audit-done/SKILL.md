---
name: audit-done
description: Mark a file or directory as audited for a given audit type. Records the current git HEAD so future runs can detect staleness.
---

# Audit Done

Mark the given path as audited for the given audit type at the current git HEAD.
Use this for an operator recording a review that already happened, after the
reviewed content has been committed.

**Compatibility**: Requires Git, Python 3.11+, and the sibling
`audit-and-fix` skill, which owns the tracker engine.

**Arguments**: `<path> <audit-type> [--note "..."]` — at least the path and the audit type are required.

## Usage

If fewer than two arguments were given, print usage and stop:

> Usage: `audit-done <path> <audit-type> [--note "..."]`
> Types: `code-quality`, `doc-quality`, `readme-quality`, `test-quality`, `code-test-coverage`
> Example: `audit-done app/features/suggestions/engine.py code-quality`

## Execute

First validate and canonicalize the subject:

```bash
python3 .agents/skills/audit-and-fix/tracker.py validate-path <path> <audit-type> --format json
```

Stop on a non-zero exit. If the valid result carries `"configured": false`, the audit can be performed in path-only mode but cannot be recorded; point to the `audit-and-fix` README for opt-in.

Before recording, verify that the canonical path has no staged or unstaged changes. If it does, stop and ask for those audited changes to be committed first: `done` records the current `HEAD`, so recording before the content commit makes the audit immediately stale.

Then run with the canonical path returned by validation, passing through the optional note:

```bash
python3 .agents/skills/audit-and-fix/tracker.py done <canonical-path> <audit-type> [--note "..."]
```

Report the tracker's response. If Git or audit configuration changed after validation and `done` now says the path is not applicable, run `refresh` and retry once; if it still fails, report the race instead of weakening validation.

Commit only the updated `docs/work/audits/records/<audit-type>.json` in a record-only metadata commit so the shared record names the already-reviewed content commit.
