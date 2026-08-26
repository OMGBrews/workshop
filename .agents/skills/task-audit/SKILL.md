---
name: task-audit
description: Audit task documents for staleness against the codebase and git history — the whole queue, or one task in depth as a pre-flight before working on it
---

# Audit Tasks

Audit task documents in this repo's tasks directory against the current codebase and git history — then update verifiable items, flag completed tasks, and report findings.

This command checks task **status and relevance** — not formatting or style, and
not bucket placement: planning rebalancing and deletion belong to
`task-reprioritize`, while lifecycle moves belong to `task-finalize` and `task-move`.
This audit only **records signals** that bear on priority
and hands them off.

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/` — written as `<tasks>/` below. If none exists, print "No tasks directory found — invoke the `task-create` skill to scaffold one." and stop.
- **Queue**: `<tasks>/queued/` (when it exists) holds tasks claimed by the autonomous runner — exclude it from the audit; the runner re-verifies its own briefs at pickup.
- **Creation dates** are not recorded in the documents — derive them from git: `git log --diff-filter=A --follow --format=%cs -- <task-file>`. Use the date only when reporting a task's age. For windowing history, use the creating *commit* (`--format=%H` on the same command, `| tail -1`) and a `<sha>..HEAD` range — never `--since=<date>`, which silently excludes commits merged after the task was written but dated before it.

## Modes

- **Fleet audit** (no argument): audit every task in every bucket, breadth-first.
- **Single-task audit** (argument names a task): a depth-first pre-flight answering "I'm about to work on this — is it still valid, and what has changed underneath it?". Resolve the argument to one task file (match by path, filename, or title; if ambiguous, list the matches and ask). Run the same phases for just that task, but analyze with a single subagent (or inline) at full depth — read the referenced code and docs rather than only confirming they exist. Skip Phase 6, and end the report with an explicit verdict: **Ready to work** / **Needs rework** (context drifted — say exactly what changed) / **Partially done** / **Superseded** / **Complete**.

Execute the following phases in order.

---

## Phase 1 — Gather Context

1. Read `<tasks>/README.md` to refresh on the task document format and conventions.

2. List all `.md` files under `<tasks>/` (with a file-glob lookup; bucket folders: `now/`, `soon/`, `later/`, `finalized/`, `never/`). **Exclude README files, `_TEMPLATE.md`, `focus.md`, and everything under `queued/`** — the first three describe the folder or the repo's current focus, not tasks; the queue is the runner's. Finalized briefs remain in scope because their code observations can rot while they wait. `focus.md` in particular sits at the tasks root beside the buckets and is prose, not a task document: audited as one it fails every structural check it was never meant to pass.

3. Read every task document. For each, extract:
   - YAML frontmatter (`status`, `effort`, `priority`, `dependencies`); the creation date comes from `git log --diff-filter=A --follow` when needed
   - The **In brief** paragraph (plain-language summary — Phase 2 checks it still matches reality)
   - Goal summary (from Goal or Problem statement section)
   - Acceptance-criteria checklist items (`- [ ]` and `- [x]`)
   - File paths, class names, and code references mentioned anywhere
   - Cross-task references (mentions of other task names or files)
   - Open questions

4. Capture recent git history for orientation:
   ```bash
   git log -15 --oneline
   git diff HEAD~15..HEAD --stat
   ```
   This window is orientation only — Phase 2 scopes history to each task, so old tasks
   are not judged against a window that predates nothing they mention.

5. Print a summary: "Found N task documents. Loaded recent commits."

---

## Phase 2 — Analyze Tasks

Launch **up to 3 parallel analysis agents**, each analyzing a batch of tasks. Divide task documents roughly evenly across agents. If there are 3 or fewer tasks — or this is a single-task audit — use a single analysis agent at full depth.

Each analysis agent receives:
- The full text of its assigned task documents
- The git log and diff stat from Phase 1
- The analysis protocol below

### Per-task analysis protocol

For each task, the analysis agent must:

1. **Codebase evidence** — search (glob and grep) for files, classes, features, and patterns the task describes. Note what exists, what's missing, and what has changed.

2. **Git history evidence** — Scope history to the task, not a fixed window:
   - The task file's own history: `git log --follow --oneline -- <task file>` (when it was created, moved between buckets, last revised).
   - Work landed since the task was written: `git log --oneline <vintage>..HEAD -- <referenced paths>` over the files and directories the task mentions, where the vintage is the frontmatter `finalized-at:` SHA when present (the brief was re-verified there), else the creating commit (see Repo conventions). Note any commits that partially or fully address the task, and any that changed its ground truth.

3. **Acceptance-criteria evaluation** — For each `- [ ]` item, determine:
   - **Verifiably complete**: Codebase evidence confirms the criterion is met. Note the evidence.
   - **Partially complete**: Some evidence exists but the criterion isn't fully met. Note what's done and what remains.
   - **No evidence**: Nothing found to suggest progress on this item.

4. **Dependency verification** — Check the frontmatter `dependencies:` list and any in-prose references to other tasks: does each listed slug match an existing task file (or, in queue repos, the queue's git history)? Flag slugs that match nothing (typo or deleted dependency). Does the depended-on work actually exist in the codebase/git history as described? Note dependencies that have since landed — a fully-unblocked task is a reprioritization signal (step 6).

5. **Context freshness** — Are file paths mentioned in the task still valid? Have referenced dependencies, tools, or features changed? Are open questions now answerable from the codebase? Does the **In brief** paragraph still match reality — flag it if the findings contradict its plain-language story.

6. **Reprioritization signals** — Record (do **not** act on) evidence that bears
   on bucket placement, for the `task-reprioritize` skill to consume:
   - The task appears fully complete (all acceptance criteria met)
   - The task's core problem has been mostly solved
   - The task's context has shifted enough to warrant re-evaluation
   - The task blocks, or is blocked by, other work (name it) — including a `dependencies:` entry that has now landed
   - A documented parking/deferral rationale no longer holds

Each analysis agent returns structured per-task analysis with evidence for every finding.

---

## Phase 3 — Apply Safe Updates

Using a text-editing tool, apply the following **safe, non-destructive** updates to task documents:

### Auto-apply

- **Check off verifiably complete acceptance criteria**: Change `- [ ]` to `- [x]` and append a parenthetical evidence note. Example:
  ```
  - [x] Widget supports dark mode *(verified: dark mode styles in widget.css lines 45-60)*
  ```
- **Update stale file paths** in Context sections when the file has clearly moved or been renamed (and the new path is unambiguous).
- **Add cross-task dependency notes** where a referenced task is now complete — add a brief note in the Context section or next to the reference.
- **Note answered open questions** with evidence from the codebase — add the answer inline, clearly marked.

### Do NOT auto-apply

- Task deletion (even if fully complete)
- Bucket changes (moving files between folders)
- Any change that requires judgment about intent or correctness

Print a summary of changes per file:
```
### Changes Applied
- [file]: checked off N acceptance criteria, updated M references
```

If no changes were needed, print "No updates needed — all tasks are current."

---

## Phase 4 — Status Updates (interactive)

Compare each task's frontmatter `status:` against the evidence from Phase 2. Determine the actual status using these rules:

- **not-started** → **in-progress**: At least one acceptance criterion is now checked off, or git history shows commits addressing the task.
- **in-progress** → **not-started**: No acceptance criteria checked off and no relevant commits found (status was set prematurely).
- **Any** → **blocked**: Analysis reveals a blocker (missing dependency, upstream issue, waiting on external input) noted in the task or discovered during analysis.
- **blocked** → **in-progress**: The documented blocker appears to be resolved based on codebase evidence.

Valid status values are: `not-started`, `in-progress`, `blocked`. (Completed tasks are deleted, not status-updated — see Phase 5.)

If any task's documented status differs from its actual status, compile the list of proposed changes and ask with a multi-select prompt. Each option is one proposed change — label format: `task-name: "old-status" → "new-status"`, description is a one-line evidence summary.

For each change the user accepts, update the frontmatter `status:` field in the task document using the text-editing tool.

If there are no status mismatches, skip ahead.

---

## Phase 5 — Flag Completed Tasks

For tasks where **all** acceptance criteria are now checked off (either previously or in Phase 3):

- Compile an evidence summary explaining why the task appears complete
- Flag the task for removal with evidence (the deletion itself happens via the `task-reprioritize` skill)
- State which bucket folder the task is in

For tasks that are **nearly complete** (most criteria checked, a few remaining):

- List the remaining unchecked items
- Note how close the task is to completion

---

## Phase 6 — Cross-Cutting Observations

Review all analysis results for broader patterns. Report these but do **not** auto-apply:

- **Superseded tasks**: Tasks that overlap or have been made redundant by other work.
- **Orphaned dependencies**: References to removed files, deleted features, or defunct tools.
- **Stale context**: Tasks whose problem description no longer matches reality.

---

## Phase 7 — Final Report

Print a structured report with these sections:

### Changes Applied
List every edit made in Phase 3, grouped by file.

### Status Updates Applied
For each status change accepted by the user: file path, old status, new status, and evidence.

### Tasks Flagged for Removal
For each fully complete task: file path, evidence summary, and recommendation.

### Nearly Complete Tasks
For each nearly-done task: file path, remaining items, and what's needed to finish.

### Reprioritization Signals
The Phase 2 signals that bear on bucket placement (complete, mostly solved,
blocking/blocked, landed dependencies, invalidated parking rationale), each with
its evidence. Do not propose or apply moves here — close by suggesting
the `task-reprioritize` skill if any signals were found.

### Cross-Task Dependency Updates
Notes on inter-task references that have changed.

### Context Changes Noted
Stale references, answered questions, shifted context.

### Tasks Found Current
List tasks that passed all checks with no issues.

Omit any section that has no entries (don't print empty sections).

End the report with:

> Do **NOT** auto-commit. Review the changes and commit when satisfied.
