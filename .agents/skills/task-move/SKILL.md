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

## Phase 3 — Move

Move the file. `git add` the source first so this works whether the task is untracked (newly created), tracked-clean, or tracked-modified — `git mv` alone errors on untracked sources:

```bash
git add <tasks>/{source-bucket}/{task-name}.md \
  && git mv <tasks>/{source-bucket}/{task-name}.md <tasks>/{target-bucket}/{task-name}.md
```

## Phase 4 — Confirm

Print: "Moved `{task-name}.md` from `{source-bucket}/` to `{target-bucket}/`."

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

2. Confirm `git status --short` shows only this move staged, and commit it on
   the default branch.
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
