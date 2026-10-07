---
name: audit-done
description: Mark a file or directory as audited for a given audit type. Records the current git HEAD so future runs can detect staleness.
---

# Audit Done

Mark the given path as audited for the given audit type at the current git HEAD
of the repository that holds it. Use this for an operator recording a review
that already happened, after the reviewed content has been committed.

**Compatibility**: Requires Git, Python 3.11+, and the sibling
`audit-and-fix` skill, which owns the tracker engine.

**Arguments**: `<path> <audit-type> [--note "..."] [--repository <name>]` — at least the path and the audit type are required. `--repository` names a nested repository declared in the audit config; `<path>` is then relative to that repository's root.

## Usage

If fewer than two arguments were given, print usage and stop:

> Usage: `audit-done <path> <audit-type> [--note "..."] [--repository <name>]`
> Types: `code-quality`, `doc-quality`, `readme-quality`, `test-quality`, `code-test-coverage`
> Example: `audit-done app/features/suggestions/engine.py code-quality`
> Example: `audit-done src/core.py code-quality --repository library`

## Execute

Run every command from the root of the repository that holds the audit config.
First validate and canonicalize the subject:

```bash
python3 .agents/skills/audit-and-fix/tracker.py validate-path <path> <audit-type> [--repository <name>] --format json
```

Stop on a non-zero exit; a path inside a declared nested repository given without `--repository` is refused, and the error names the spelling to use. If the valid result carries `"configured": false`, the audit can be performed in path-only mode but cannot be recorded; point to the `audit-and-fix` README for opt-in.

Before recording, verify that the canonical path has no staged or unstaged changes in the repository that holds it (`git -C <subject-root> status --porcelain -- <path>` for a nested repository, whose root is the `path` declared for it in `docs/work/audits/config.toml`). If it does, stop and ask for those audited changes to be committed first: `done` records the current `HEAD`, so recording before the content commit makes the audit immediately stale.

Then run with the canonical path returned by validation, passing through the optional note and repository:

```bash
python3 .agents/skills/audit-and-fix/tracker.py done <canonical-path> <audit-type> [--note "..."] [--repository <name>]
```

Report the tracker's response. If Git or audit configuration changed after validation and `done` now says the path is not applicable, run `refresh` and retry once; if it still fails, report the race instead of weakening validation. For a nested repository, `done` records that repository's `HEAD` and refuses a commit outside its history; it never fetches.

Commit only the updated record — `docs/work/audits/records/<audit-type>.json`, or `docs/work/audits/records/<name>/<audit-type>.json` for a nested repository — in a record-only metadata commit, staged by explicit pathspec, so the shared record names the already-reviewed content commit. Never include a nested repository's gitlink, and do not push, open a pull request, or move a submodule pointer as part of recording.

This is also how a nested-repository review that landed through a squash-merged or rebased pull request is re-recorded: the tracker reports the path as stale because the recorded commit left the subject's history, and once the landed commit is checked out in the subject, `audit-done <path> <audit-type> --repository <name>` records it without a new review.
