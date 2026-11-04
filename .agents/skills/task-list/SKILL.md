---
name: task-list
description: List all tasks in the tasks directory with status summary
---

# List Tasks

Summarize all tasks in this repo's tasks directory.

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/` — written as `<tasks>/` below. If none exists, print "No tasks directory found — invoke the `task-create` skill to scaffold one." and stop.
- **Lifecycle buckets**: `<tasks>/finalized/` holds briefs ready for supervised implementation; any surviving `<tasks>/queued/` briefs are legacy recovery work. List them separately from the planning buckets.

## Phase 1 — Find Tasks

List all `.md` files in `<tasks>/now/`, `<tasks>/soon/`, `<tasks>/later/`, `<tasks>/finalized/`, and `<tasks>/parked/` (with a file-glob lookup). Exclude `README.md` and `_TEMPLATE.md` files.

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
- **Parked details**: For each `parked/` brief, extract `**Why**:` and
  `**Unpark when**:` from its `## Parked` section and optional frontmatter
  `unpark-after:`. Use the [canonical bucket definitions](../task-create/bucket-definitions.md)
  relative to this skill's physical directory. Flag a missing, misplaced,
  duplicated, or incomplete note; empty text, comment-only text, and placeholders
  such as `<reason>`, `TODO`, or `TBD` are not substantive. Also flag
  `status: in-progress` as a parked/status contradiction.

A task with bold-metadata lines (`**Status**: Not Started`) instead of frontmatter predates the 2026-07 format convergence — extract the equivalent fields, and note at the end of the report that Workshop's `Tools/migrate-task-format.sh` converts the repo (resolve the tool from this skill's physical directory — [`skill-path-resolution.md`](../../../docs/skill-path-resolution.md)).

## Phase 3 — Present Results

Print one table per bucket, in this order: Finalized, Now, Soon, Later, Parked. Only include buckets that have tasks. Label Finalized as “ready for supervised implementation” so it is not mistaken for completed work.

Format:

### Now (N tasks)
| Task | Status | Effort | Priority | Progress | Goal |
|------|--------|--------|----------|----------|------|
| task-name | in-progress | medium | high | 2/5 | First sentence of goal... |

Append ` (deps: a, b)` to the Task cell when the task lists dependencies.

For the Parked table, add **Unpark when**, **Unpark after**, and **Flags**
columns. Show the condition beside every brief, or `missing` when absent.
Compare valid `unpark-after: YYYY-MM-DD` calendar dates with today's date,
stating the date used; flag dates on or before today as `due for review`.
Flag malformed or repeated date fields and dates that contradict the prose
condition instead of guessing. An absent date is allowed. Listing displays
conditions and date signals; it does not investigate code or dependency
completion. Never move a task automatically: suggest `task-status` or
`task-audit` for evidence review and `task-move` for an intentional move.

If `<tasks>/queued/` exists and holds task files, add a final read-only section:

### Legacy queued briefs (N tasks — recovery required)
| Task | Priority | Effort |
|------|----------|--------|

After all tables, print a totals line:

**Total: N tasks across all buckets, X/Y acceptance criteria complete.**
