---
name: task-move
description: Move a task between priority buckets
---

# Move Task

Move a task file between priority buckets in this repo's tasks directory.

**Arguments**: `[task-filename] [target-bucket]` (e.g., `fix-login-crash now`).

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/` — written as `<tasks>/` below. If none exists, print "No tasks directory found — invoke the `task-create` skill to scaffold one." and stop.
- **Retired queue**: `queued` is never a valid target. Recover legacy queued briefs only after checking for surviving processes and unfinished work.

## Phase 1 — Find the Task

Search for the task file across all buckets (`now/`, `soon/`, `later/`, `finalized/`, `parked/`, and `queued/` where it exists). Match by filename (with or without `.md` extension).

If the task is not found, list available tasks and ask the user to pick one.

If no task name was provided in the arguments, list all tasks and ask which one to move.

## Phase 2 — Validate Target

If no target bucket was provided in the arguments, ask where to move it. Valid targets: `now`, `soon`, `later`, `parked`. `finalized` is not a manual target: successful `task-finalize` owns admission so every brief there has passed readiness.

If the task is already in the target bucket, print "Task is already in `{bucket}/`." and stop.

### Parking and rejection checks — before staging

Read the [canonical bucket definitions](../task-create/bucket-definitions.md)
relative to this skill's physical directory. Apply these checks before any
`git add` or move:

- **Moving into `parked/`:** collect why the work is being set aside and the
  condition that should bring it back. If the user already supplied substantive
  answers, use them; otherwise ask for the missing answers. Confirm an existing
  note still describes the intended deferral. Empty answers, HTML comments,
  and placeholders such as `<reason>`, `TODO`, or `TBD` do not count.
- When parking, write or update exactly one `## Parked` section immediately after the
  `**In brief**:` paragraph and its optional `**Issues**:` line, with substantive
  `**Why**:` and `**Unpark when**:`
  entries. Preserve the rest of the brief; do not append a duplicate section.
  When the condition includes a date, optionally record a matching
  `unpark-after: YYYY-MM-DD` frontmatter value. A date field never replaces
  the note. Resolve malformed dates or contradictions with the condition
  before proceeding. The filename stays unchanged on park and unpark.
- **Parking with `status: in-progress`:** refuse to park it until the user explicitly
  chooses a truthful correction to `not-started` or `blocked`. Do not silently
  change its status or infer that asking to park supplied that correction.
  Apply the agreed correction before staging the move.
- **Moving out of `parked/`:** inspect the brief for `## Rejection rationale`.
  If present, stop and explain that this revives rejected work. Proceed only
  after explicit confirmation naming this one task. A bulk or filter-driven
  move must exclude it and report the exclusion, even when the user approved
  the bulk move; offer a separate individual move for deliberate confirmation.

Before parking, read back the resulting note and status. If a required answer
or confirmation for either direction is missing, leave the move unstaged and
wait for it.

## Phase 3 — Move

Read [repair-moved-task-links.md](repair-moved-task-links.md) relative to this
skill file's **physical** directory, following symlinks first. Perform its
pre-move steps: inspect existing staging, discover local tooling, record the
old/new pair, and capture original link targets and inbound references.

Move the file. `git add` the source first so this works whether the task is untracked (newly created), tracked-clean, or tracked-modified — `git mv` alone errors on untracked sources. If the source contains unrelated edits, preserve those hunks separately rather than staging them with the move:

```bash
git add <tasks>/{source-bucket}/{task-name}.md \
  && git mv <tasks>/{source-bucket}/{task-name}.md <tasks>/{target-bucket}/{task-name}.md
```

Then perform the shared procedure's repair phase: prefer an existing mechanical
repair, restore outbound links from their original targets, and stage the move
and associated repairs together. Run the existing repository link check, or
inspect affected references manually if none exists. A failed repair/check or
an unresolved reference stops here with changes available for inspection;
do not proceed to confirmation or shipping.

## Phase 4 — Confirm

Print: "Moved `{task-name}.md` from `{source-bucket}/` to `{target-bucket}/`."
Name the repaired files and the link-check result, or the manual verification
performed when no check exists.

## Phase 5 — Ship it (docs-only fast path)

Offer to ship the move immediately after Phase 4 — task moves are the exact
churn the docs-only fast lane exists for. The rules are the repo's adopted
shipping convention, never a repo-local heading: resolve the Workshop tree
from this skill's **physical** directory (per
[`../../../docs/skill-path-resolution.md`](../../../docs/skill-path-resolution.md)),
ask its predicate, and apply the convention's local-versus-PR rule.

1. Resolve the tree root — `readlink -f` follows every symlink, so either
   skill surface resolves:

   ```bash
   TREE_ROOT="$(dirname "$(readlink -f .agents/skills/task-move/SKILL.md)")/../../.."
   ```

2. After the user accepts the shipping offer, confirm the staged diff contains
   only this move and its associated link repairs, with unrelated staging
   preserved and excluded from the commit. Commit those paths/hunks on the
   default branch only where the repository permits that route.
3. Run the predicate from the repo root against the remote default branch:

   ```bash
   bash "$TREE_ROOT/Tools/docs-only-diff.sh" origin/main; echo "EXIT=$?"
   ```

   Exit 0 → the docs lane: offer to push now, and read the push's own output
   as the verification. Any other exit → do **not** push: name the paths that
   fall outside the declared surface and leave the commit local for the
   normal flow. Exit 2 means the repo declared no prose surface — no fast
   lane exists, which is an answer, not a failure to read.

Neither exit grants consent: the offer is the ask, and the user's acceptance
of the offer is the authorization. In a cloud session or a PR-required repo,
neither this skill nor any other public task skill opens or merges a PR and
none assumes the shared `ship` skill is installed — report that the committed
change is ready and hand off to the repository's documented PR workflow.
