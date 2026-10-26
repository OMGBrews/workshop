---
status: <not-started | in-progress | blocked>
effort: <small | medium | large>
priority: medium
dependencies: []
---

<!-- Template for new tasks. Copy this file into a planning bucket (`now/`,
     `soon/`, `later/`) under the repo's tasks directory (`docs/work/tasks/`),
     fill in the placeholders, and delete this preamble block plus
     any optional sections you don't need.

     Frontmatter fields (all four required; the task skills parse them):
       - `status` — `not-started` | `in-progress` | `blocked`.
           `not-started`: filed, no work begun. `in-progress`: a human or
           Claude session is actively working it. `blocked`: work cannot
           continue until an *external* dependency resolves (someone
           else's PR, a third-party fix, a vendor decision) — use
           `## Open questions` for blocking decisions, not this field.
           Completed tasks are deleted (git preserves history); parked
           tasks go to `never/` — see `bucket-definitions.md`, beside
           this template. There is no `done` status.
       - `effort` — `small` | `medium` | `large`.
       - `priority` — `high` | `medium` | `low`. Default `medium`.
       - `dependencies` — task filenames minus `.md` that must be completed
           before implementation. Default `[]`. Verify completion from current
           evidence and history; absence alone can also mean renaming or rejection.
           `task-implement` prunes satisfied edges on confirmed close-out.

     One further field is machine-written — do NOT fill it by hand:
       - `finalized-at` — a conservative comparison baseline shared by the
           inspected commit and freshly fetched default branch when possible.
           `/task-finalize` falls back to the inspected commit with a
           limited-durability disclosure; consumers fully re-verify when the
           stamped history is unavailable or outside current ancestry.

     There is no `created` field and no Created line — a task's creation
     date is derived from git when needed:
     `git log --diff-filter=A --follow --format=%cs -- <task-file>`.
     A recorded date goes stale on every edit; git's does not.

     Filename: kebab-case, action-verb-first, `.md` extension
     (e.g. `persist-draft-autosave-flag.md`, `restore-thumbnail-cache-on-startup.md`).
     Don't use `README.md` or `_TEMPLATE.md` — those are reserved.

     Audience: human task authors and the `/task-create`, `/task-finalize`,
     `/task-move`, and `/task-audit` skills.

     Key references — open these if you're unsure what to write:
       - `bucket-definitions.md`, beside this template — what each bucket
         means and the shape the queue aims for; the definition of record,
         which every repo's own bucket list only summarizes
       - the tasks directory's `README.md` — when to file a task, and any
         repo-specific authoring notes (domain jargon to avoid in In brief,
         area maps, completion requirements)
       - `/task-finalize` — interactive open-questions resolver that also
         validates readiness and moves passing briefs into `finalized/` -->

# Task Title

<!-- Replace with a clear, concise title describing the desired outcome. -->

**In brief**: <!-- REQUIRED. One short paragraph (~5 lines) in plain language,
     for triage. What's wrong or missing → why it matters → where it stands now.
     No jargon, no identifiers, no file paths — and "jargon" includes this
     repo's domain terms whose meanings differ from plain English (the tasks
     README lists any). Someone who has never opened this repo, technical or
     not, should understand it. The Goal section below stays technical; this
     does not. -->

## Goal

<!-- REQUIRED. 1-3 sentences: what this task achieves and why it matters.
     Start with an action verb. Scannable in 5 seconds. -->

## Context

<!-- OPTIONAL — delete for trivial tasks.
     Background needed to understand the work: what exists today, what's broken
     or missing, relevant history. Include file paths when they define the
     problem scope.
     Anchor code references durably: a symbol name plus a short greppable
     quote (`run_tools`'s `if isinstance(result, Exception)` branch) outlives
     a bare line number, which rots with every commit. Line numbers are a
     secondary convenience at most — the worker that reads this brief may be
     weeks away. -->

## Recommended solution

<!-- OPTIONAL — usually written by `/task-finalize`, not at creation time.
     At creation you often don't know the solution yet; that's what
     `## Open questions` is for. `/task-finalize` verifies the task against
     HEAD, resolves the questions, and writes the design here while the
     analysis is fresh — the strongest model prepares what a later session
     (or the autonomous worker) executes.
     ADVISORY, NOT CONTRACT: the acceptance criteria remain what the worker
     is graded on. The worker follows this design unless the code at HEAD
     contradicts it, and notes any deviation. Ground each design point in
     verified code (durable anchors, per the Context note above); delete the
     section for tasks whose approach is obvious from Goal + acceptance
     criteria. -->

## Scope

<!-- OPTIONAL — delete if the task is self-evidently scoped from the Goal.
     Which files, modules, or subsystems this task touches.
     Be specific: list file paths, not "the frontend."
     If this task follows a procedure, link it here. -->

## Acceptance criteria
<!-- AC:BEGIN — DO NOT REMOVE: /task-finalize, /task-audit, and /task-status parse the AC list between these sentinels. -->

<!-- REQUIRED. What must be true when done. Describe capabilities and outcomes,
     NOT implementation steps. Write "users can view a report" not
     "create a ReportManager class".
     Use checkboxes for trackable items. Group under sub-headings if needed. -->

- [ ] <first acceptance criterion>
- [ ] <second acceptance criterion>

<!-- AC:END -->

## Stopping conditions

<!-- REQUIRED. When should the agent stop? Not just "when requirements are met" —
     what does "met" look like in measurable terms?
     For iterative tasks: what triggers the final iteration?
     For one-shot tasks: what verification command confirms completion? -->

<!-- ## Decisions

     Populated by `/task-finalize` (which migrates resolved open questions
     here), or write entries yourself when resolving questions outside the
     skill. Uncomment this section and the heading above when you have
     decisions to record; leave it commented otherwise.

     Format: `- **Q: <question>** — <answer>` per entry.

     Placement matters: `/task-finalize` inserts here, immediately after
     `## Stopping conditions` — falling back to immediately before
     `## Out of scope`, then to end of file, where those sections are
     absent. Don't reorder the surrounding sections. -->

## Open questions

<!-- OPTIONAL — delete if there are none.
     Unresolved decisions for planning. Resolve all open questions BEFORE
     handing this task to an agent (or run `/task-finalize` to walk them
     interactively). Every unresolved question is a point where the agent
     will need human guidance or make the wrong choice.
     If a question can't be resolved, decompose the task: create a separate
     investigation task for the question, then scope this task to the
     known-good path. -->

## Out of scope

<!-- OPTIONAL — delete if not needed.
     What this task does NOT include. Prevents scope creep. -->

<!-- See also (for template readers, not authored tasks):
       - `./README.md` — task bucket map and repo-specific authoring notes
       - `/task-finalize`, `/task-move`, `/task-audit` — skills that consume
         this template -->
