---
name: task-create
description: Create a new task from the template
---

# Create Task

Create a new task document in this repo's tasks directory.

**Arguments**: optional `[task-name]` in kebab-case.

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/` — written as `<tasks>/` below.
- **Queue**: anything mentioning `<tasks>/queued/` applies only when that directory exists (it feeds the autonomous task-queue runner). In repos without it, skip those parts silently.
- **Repo-specific authoring notes** (domain jargon to avoid in In brief, area maps, completion gates) live in `<tasks>/README.md` — read it before writing prose on the user's behalf.
- **Bucket definitions**: [`bucket-definitions.md`](bucket-definitions.md), the file next to this one — what each bucket means and the shape the queue aims for, shared with every other task skill so they cannot drift. A repo's own bucket lists are courtesy summaries of it, never a second definition.

## The template is single-source

The canonical task template is [`_TEMPLATE.md`](_TEMPLATE.md), the file next to this
one — the only copy. Repos carry **no** `<tasks>/_TEMPLATE.md` at all: a task is
created by reading this file and copying it into `<tasks>/{bucket}/` (Phase 3). A
tasks-root copy is what let the template drift into seven per-repo variants before
the 2026-07-26 convergence; the symlink that held the convergence in place, and the
gates that demanded it, were retired together, leaving the canonical file here alone.

Resolve this file from the skill's **physical** directory per
[`skill-path-resolution.md`](../../../docs/skill-path-resolution.md) — never through a
consumer's `.claude/` bridge. Prose pointers elsewhere in the fleet name the canonical
surface, `.agents/skills/task-create/_TEMPLATE.md`.

## Phase 1 — Check Structure

If no tasks root exists at all, offer to create one at `docs/work/tasks/` (the
machine-owned location):
- `docs/work/tasks/` with a `README.md` — the template is not copied or linked into
  the tasks root; Phase 3 reads the canonical file from inside this skill.
- `docs/work/tasks/now/`, `docs/work/tasks/soon/`, `docs/work/tasks/later/`, `docs/work/tasks/never/` each with a one-liner `README.md`. Write each one-liner from [`bucket-definitions.md`](bucket-definitions.md) and point at it for the definition of record — the one-liner is a courtesy summary, not a second definition. Write that pointer as the repo-root-relative path in prose (`.agents/skills/task-create/bucket-definitions.md` — the repo's own canonical skills surface, whatever the devtools tree is mounted as, per [`skill-path-resolution.md`](../../../docs/skill-path-resolution.md)), **not** a markdown relative link: the tree sits outside the tasks tree, so a `../../..` hyperlink renders broken on GitHub even where it resolves on disk. (Do **not** create `q…ueued/` — an autonomous queue is a deliberate per-repo opt-in, not scaffolding.)

If the user declines, stop.

## Phase 2 — Gather Info

1. If no task name was provided in the arguments, ask for one (kebab-case, action-verb-first, e.g., `fix-login-crash`).
2. Ask which bucket to place the task in. Options: `now`, `soon` (default), `later`. (`never/` is not offered at creation — a task is parked there later via the `task-move` skill; see [`bucket-definitions.md`](bucket-definitions.md). Tasks heading for autonomous execution are still created in a normal bucket first — `task-finalize` gets them ready, and `task-move` promotes them to `queued/` once they pass readiness.)
3. Ask for a brief goal statement (1-2 sentences starting with an action verb).
4. Ask for effort estimate: `small`, `medium` (default), or `large`.
5. Priority defaults to `medium` and dependencies to `[]` — don't ask unless the user signals urgency (then offer `high`/`medium`/`low`) or names other tasks this one must wait for (then record their slugs as dependencies).

## Phase 3 — Create File

1. Read this skill's own `_TEMPLATE.md` — the file next to this one, resolved from the
   skill's **physical** directory per
   [`skill-path-resolution.md`](../../../docs/skill-path-resolution.md), never through a
   consumer's `.claude/` bridge.
2. Copy it to `<tasks>/{bucket}/{task-name}.md`.
3. Fill in:
   - Replace `# Task Title` with `# {title}` (derived from task-name, converting kebab-case to sentence case — capitalize only the first word and proper nouns, per the doc style guide).
   - In the YAML frontmatter: set `status: not-started`, `effort:` and `priority:` to the chosen values, and `dependencies:` to the recorded slugs (or `[]`).
   - Replace the Goal section placeholder with the provided goal statement.
   - Write `**In brief**:` — one short plain-language paragraph derived from the goal
     statement, following the guidance in the template's comment (no jargon, no
     identifiers, no file paths — including any repo domain terms flagged in
     `<tasks>/README.md`). It exists so a reader can triage the task without opening
     the codebase, so write it for someone who has never seen this repo. Show it to
     the user and adjust if they want it different.

   Do **not** add a Created line or `created:` field — the creation date is derived from `git log --diff-filter=A --follow` when needed.
4. Remove HTML comments from the sections that were filled in (Goal metadata block, the `**In brief**:` paragraph). Leave HTML comments in unfilled sections as guidance.
5. Strip the template-only preamble (the HTML-comment block above `# Task Title` describing the template's purpose and listing key references) and the See-also footer (HTML-comment block at the very end). Both are meant for readers of the template, not for authored tasks.

## Phase 4 — Confirm

Print: "Created `<tasks>/{bucket}/{task-name}.md`."

## Phase 5 — Offer to Finalize

The `task-finalize` skill walks open questions interactively, verifies the task's claims against HEAD, and validates readiness. It does not move the task: in repos with a queue, promotion to `queued/` is a separate `task-move` run once finalization passes.

Ask a single-select question (one option only) to offer it:

- **question**: "Run `task-finalize` now to verify against HEAD and resolve open questions?"
- **header**: "Finalize now?"
- options:
  - `Yes — finalize now` — invoke the `task-finalize` skill on this task immediately, passing the new file path as the argument. (Recommended when the task is small and the open questions are already in your head.)
  - `No — leave it here` — stop. The user will run `task-finalize` later.

If the user picks Yes, hand off to `task-finalize <path-to-new-task>`. If No, stop.

## Phase 6 — Ship it (docs-only fast path)

Runs only when Phase 5 ended with "No — leave it here" (a finalize hand-off
reaches the same offer through `task-finalize`'s own closing phase). If the
repo's AGENTS.md documents a docs-only shipping convention (a "Shipping
docs-only changes" section naming a predicate script), offer to ship the new
task now:

- **Local session** (pushes to the default branch are not blocked): confirm
  `git status --short` shows only this task file, commit it on the default
  branch, then run the predicate script against the remote default branch
  (e.g. `scripts/docs-only-diff.sh origin/main`). Exit 0 → push, and read the
  push's own output as the verification. Any other exit → do **not** push:
  name what else the outgoing range carries and leave the commit local.
- **Cloud session** (git proxy, PR flow): note that the `ship` skill carries docs-only
  PRs to merge without a review pause under the maintainer's standing
  delegation (2026-07-29).

No such AGENTS.md section → stop; shipping stays the session's normal flow.
