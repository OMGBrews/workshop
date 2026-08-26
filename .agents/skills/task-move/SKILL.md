---
name: task-move
description: Move a task between priority buckets
---

# Move Task

Move a task file between priority buckets in this repo's tasks directory.

**Arguments**: `[task-filename] [target-bucket]` (e.g., `fix-login-crash now`).

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/` — written as `<tasks>/` below. If none exists, print "No tasks directory found — invoke the `task-create` skill to scaffold one." and stop.
- **Queue**: `<tasks>/queued/` exists only in repos running the autonomous task-queue runner. Where it is absent, `queued` is not a valid bucket and Phase 3 never applies.

## Phase 1 — Find the Task

Search for the task file across all buckets (`now/`, `soon/`, `later/`, `finalized/`, `never/`, and `queued/` where it exists). Match by filename (with or without `.md` extension).

If the task is not found, list available tasks and ask the user to pick one.

If no task name was provided in the arguments, list all tasks and ask which one to move.

## Phase 2 — Validate Target

If no target bucket was provided in the arguments, ask where to move it. Valid targets: `now`, `soon`, `later`, `never` — plus `queued` in repos where `<tasks>/queued/` exists. `finalized` is not a manual target: successful `task-finalize` owns admission so every brief there has passed readiness.

If the task is already in the target bucket, print "Task is already in `{bucket}/`." and stop.

## Phase 3 — Readiness Check (only when moving INTO queued/)

If the target bucket is **anything other than `queued`**, skip this phase.

Tasks in `queued/` are picked up by the autonomous task-queue runner with no further triage. Refuse moves into `queued/` unless the shared readiness checker passes against the current task file:

Resolve `check-task-readiness.sh` from the `task-finalize` skill's physical directory, then run it on the current task file and read every `PASS` / `FAIL` / `WARN` line plus the exit code:

```bash
skill_dir="$(cd -P "$(dirname "$(readlink -f .agents/skills/task-finalize/SKILL.md)")" && pwd)"
checker="$skill_dir/check-task-readiness.sh"
readiness_rc=0
readiness_output="$(bash "$checker" "$task_file")" || readiness_rc=$?
printf '%s\n' "$readiness_output"
printf 'EXIT=%s\n' "$readiness_rc"
```

Exit 0 is admission-ready. Exit 1 means the numbered `FAIL` records are the reasons to refuse; `WARN` records alone do not block the move. Exit 2 means the checker could not derive the task file's repository context, so stop and fix that before considering the move.

If the checker exits 1:

1. Print the specific failures.
2. Print: "Refusing to move into `queued/`. Run `task-finalize {task-name}` to resolve the issues interactively (it walks open questions one at a time in conversation, stamps `finalized-at:`, and runs this same checker), then re-run this move."
3. Stop without moving.

If all rules pass, proceed.

## Phase 4 — Move

Move the file. `git add` the source first so this works whether the task is untracked (newly created), tracked-clean, or tracked-modified — `git mv` alone errors on untracked sources:

```bash
git add <tasks>/{source-bucket}/{task-name}.md \
  && git mv <tasks>/{source-bucket}/{task-name}.md <tasks>/{target-bucket}/{task-name}.md
```

## Phase 5 — Confirm

Print: "Moved `{task-name}.md` from `{source-bucket}/` to `{target-bucket}/`."

If the target was `queued/`, also print: "The task-queue runner will pick this up on its next poll cycle (if running) — it reads main's HEAD, not the working tree, so this rename stays invisible to it until the commit lands. Start the runner with `bash .claude/skills/task-queue/run.sh` (the `.claude/skills/` path is the Claude Code bridge into the canonical `.agents/skills/` tree)."

## Phase 6 — Ship it (docs-only fast path)

Offer to ship the move immediately after Phase 5 — task moves are the exact
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
none assumes the private `ship` skill is installed — report that the committed
change is ready and hand off to the repository's documented PR workflow.
