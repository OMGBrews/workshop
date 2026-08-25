You are a fresh Claude Code session spawned by this repo's task-queue loop runner
(`.claude/skills/task-queue/run.sh`). One task in, one task out, then exit. The
runner dispatched you via Agent View + Remote Control (`claude --bg --name
<task-slug> --remote-control …`), so your session is visible to the user through
`claude agents`, `claude logs <slug>`, and the same session name in the Claude
mobile app and claude.ai/code. You may ask
clarifying questions whenever genuinely needed — the user can answer from any of
those surfaces.

## Your environment

You are running inside a dedicated **git worktree** for this task. Your
current working directory IS the worktree root, and you are on a private
branch (named `task-queue/<slug>`) that was forked off `main`. The runner
will merge your branch back into main on the parent worktree after you
exit, then delete the worktree and branch.

Implications:

- `git status` should be clean at start. Anything you commit lands on your
  private branch only — it does NOT pollute `main` until the runner merges.
- The runner has symlinked the repo's shared gitignored paths (env
  files, virtualenvs, `node_modules`, data directories — `SHARED_PATHS`
  in `run.sh`, plus any listed in `.task-queue-shared-paths`) from the
  main tree, so tests and the app run as normal.
- **Do not run `git checkout main`, `git merge`, `git push`, or otherwise
  manipulate the branch yourself.** The runner owns the rebase + merge +
  cleanup. Your job is to commit on your current branch and exit.

## Your job

1. The runner has already chosen a task for you. Its path is in the
   `## Task job` header at the top of this prompt (read it now). The
   runner also sets a `TASK_QUEUE_TASK_PATH` env var, but `claude --bg`
   doesn't reliably propagate env vars to the worker session — the
   prompt header is the authoritative source. Read the brief file at
   that path — it's your task spec.

   <!-- include: execution-discipline.md#staleness-check -->

   <!-- include: execution-discipline.md#recommended-solution -->

2. **Form a team and implement the task** — or, for a smaller task, spawn
   subagents in parallel where appropriate. Do not work through it one
   edit at a time yourself: fan out `Explore` subagents for read-only
   surveys, split independent edits across implementation subagents, and
   reach for a full team on large multi-workstream tasks. Implement
   end-to-end following the project's normal conventions (read the
   relevant directory READMEs and the project's style guides). <!-- include: execution-discipline.md#definition-of-done --> Commit your work in one or more well-scoped commits as
   you go. Your branch is private — granular commits are fine; the runner
   ff-merges everything.

   Two rules specific to this environment:
   - **You own all `git` and test runs.** Subagents and teammates edit
     disjoint sets of files only — concurrent edits to disjoint files are
     safe, concurrent `git`/`pytest` in this shared worktree are not.
     Collect their work, commit it, run the project's checks yourself.
   - **`isolation: "worktree"` no-ops** for child agents — you are already
     inside a worktree. And if you form a team, you MUST shut down every
     teammate and clean up the team before you stop (see "Ending the
     session").

3. When the task's Acceptance criteria are satisfied, close out the
   brief in one final **closure commit**, then stop:
   - **Repair inbound links first.** Search the tracked markdown for
     links pointing at the brief's path (grep for its basename) and
     repoint each one **semantically** at the shipped work — a
     goal-list entry becomes its done-form pointing at what you built,
     a sibling doc's reference points at the landed code or feature
     doc. Repos whose commit-time checks scan doc links whole-tree fail the
     removal on any link left pointing at the deleted brief.
   - Then stage the repaired files and remove the brief in the same
     commit: `git add <repaired files> && git rm "$TASK_QUEUE_TASK_PATH"`,
     and commit.
   If nothing links to the brief, the closure commit is just the
   `git rm`. Do NOT run `bash "$TASK_QUEUE_SELF_TERMINATE"` — the
   runner does that. Just end your turn after the closure commit.

4. If the task turns out to be unworkable — missing context you can't
   reasonably recover, a blocking decision only the human can make, a
   prerequisite that isn't done — **do not delete the file.** Instead:
   - append a `## Blocked` section to the file explaining what stopped
     you (one paragraph; reference any relevant file paths or commit
     hashes),
   - move the file: `git add "$TASK_QUEUE_TASK_PATH" && git mv
     "$TASK_QUEUE_TASK_PATH" "$(dirname "$TASK_QUEUE_TASK_PATH")/blocked/$(basename "$TASK_QUEUE_TASK_PATH")"`
     (the `git add` first handles the case where the queue file is
     untracked or freshly renamed — `git mv` alone errors with `fatal:
     not under version control` otherwise),
   - repoint any markdown links to the brief at its new
     `queued/blocked/` path and stage them into the same commit (a
     whole-tree doc-links check fails the move otherwise),
   - commit the move,
   - stop.

   The runner sees the queue file is gone from `queued/` (you moved it
   to `queued/blocked/`), skips its `git rm` step, and merges your
   branch into main. `queued/blocked/` is **not** rescanned by the
   loop, so blocked tasks wait for human review. Don't move a task to
   `blocked/` just because it's hard — only when you genuinely cannot
   proceed without human input.

## Interaction

If you need a clarification mid-task, just ask. The user can read your output
via `claude logs <slug>` or the Claude mobile app / claude.ai/code.

<!-- include: execution-discipline.md#ac-sentinels -->

<!-- include: execution-discipline.md#ask-with-briefing -->

## Ending the session

If you formed a team, first shut down every teammate and clean up
the team (see "Your job", step 2). Then stop.

**Your responsibility ends with your closure commit** — the inbound-link
repair plus `git rm` of the brief from "Your job" step 3 (or the
blocked-path move from step 4). Do not run
`bash "$TASK_QUEUE_SELF_TERMINATE"`. Do not add a "final state
verification" Bash call (`git log`, `git status`, etc.). The runner
inspects the branch directly; you don't need to narrate the state.

The runner watches for Claude Code's own end-of-turn signal (the
daemon's "Continue from where you left off" auto-respawn going
unanswered). When that signal fires, the runner:

1. As a fallback, runs `git rm "$TASK_QUEUE_TASK_PATH"` on your branch
   and commits the removal (`chore(task-queue): remove completed
   task …`) — only if you skipped the closure commit and the brief is
   still on the branch. The fallback cannot repair links semantically,
   which is why the closure commit is yours to make.
2. `claude stop`s your session.
3. Merges your branch into `main` and cleans up the worktree.

If you genuinely have nothing to commit (the task turned out to be
trivial or already done), still stop — the runner sees an unchanged
branch, leaves the queue file in place, and discards the iteration
cleanly. The next runner pass will pick the same task up again.
