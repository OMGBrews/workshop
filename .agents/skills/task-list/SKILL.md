---
name: task-list
description: List all tasks in the tasks directory with status summary
---

# List Tasks

Summarize all tasks in this repo's tasks directory.

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/` — written as `<tasks>/` below. If none exists, print "No tasks directory found — invoke the `task-create` skill to scaffold one." and stop.
- **Lifecycle buckets**: `<tasks>/finalized/` holds briefs ready for supervised implementation; `<tasks>/queued/` (when it exists) is owned by the autonomous runner. List both separately from the planning buckets.

## Phase 1 — Find Tasks

List all `.md` files in `<tasks>/now/`, `<tasks>/soon/`, `<tasks>/later/`, `<tasks>/finalized/`, and `<tasks>/never/` (with a file-glob lookup). Exclude `README.md` and `_TEMPLATE.md` files.

If no task files are found, print "No tasks found in `<tasks>/`." and stop.

## Phase 2 — Extract Metadata

For each task file, read it and extract:
- **Task**: The H1 title (first `# ` line)
- **Status**: The YAML frontmatter `status:` field (`not-started` / `in-progress` / `blocked`)
- **Effort**: The frontmatter `effort:` field (`small` / `medium` / `large`)
- **Priority**: The frontmatter `priority:` field (`high` / `medium` / `low`)
- **Dependencies**: The frontmatter `dependencies:` list, if non-empty
- **Goal**: First sentence of the Goal (or Problem statement) section
- **Progress**: Count of checked (`- [x]`) vs total (`- [ ]` + `- [x]`) acceptance-criteria checkboxes

A task with bold-metadata lines (`**Status**: Not Started`) instead of frontmatter predates the 2026-07 format convergence — extract the equivalent fields, and note at the end of the report that the devtools tree's `Tools/migrate-task-format.sh` converts the repo (resolve the tool from this skill's physical directory — [`skill-path-resolution.md`](../../../docs/skill-path-resolution.md)).

## Phase 3 — Present Results

Print one table per bucket, in this order: Finalized, Now, Soon, Later, Never. Only include buckets that have tasks. Label Finalized as “ready for supervised implementation” so it is not mistaken for completed work.

Format:

### Now (N tasks)
| Task | Status | Effort | Priority | Progress | Goal |
|------|--------|--------|----------|----------|------|
| task-name | in-progress | medium | high | 2/5 | First sentence of goal... |

Append ` (deps: a, b)` to the Task cell when the task lists dependencies.

If `<tasks>/queued/` exists and holds task files, add a final read-only section:

### Queued (N tasks — autonomous runner)
| Task | Priority | Effort |
|------|----------|--------|

After all tables, print a totals line:

**Total: N tasks across all buckets, X/Y acceptance criteria complete.**
