# Autonomous task queue — retired

Workshop no longer supplies autonomous task execution. Use the interactive
workflow: `task-next` → `task-finalize <task>` → `task-implement <task>`.
The ordinary Markdown task backlog and its dependency metadata remain supported.

Do not create `queued/`, launch an older runner directly from a pinned checkout,
or enable queue-driven CI repair. The retired skill, launch stub, and termination
helper have been removed entirely.
Separate audit runners are outside this retirement.

## Recovering old work

Retirement does not prove that another checkout has no running processes.
Inspect any existing runner processes, `.task-queue/` state, task-queue branches,
and worktrees before cleanup. Stop identified old runners gracefully and preserve
uncommitted work and branch commits for manual review; do not run automatic recovery.
Move surviving queued briefs to a planning bucket after checking ownership and
actual progress, then remove the empty `queued/` directory. A marker file is
recovery evidence, not completed work. Keep runtime ignore entries while old
state may remain. Never delete branches or worktrees merely because the runner
is retired.

The interactive implementation rules live in
[task-implement’s execution discipline](../.agents/skills/task-implement/execution-discipline.md).

Consumers advancing past this removal must first remove any legacy links to
`task-queue/self-terminate.sh` and update their local checks and audit guidance.
Existing pinned checkouts keep their own version until adoption. Refresh both
skill surfaces with `Tools/sync-skill-symlinks.sh` after advancing the pin; the
sync removes stale shared links while preserving project-local skills.
