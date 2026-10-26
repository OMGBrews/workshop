# Autonomous task queue — retired

Workshop no longer supplies autonomous task execution. Use the interactive
workflow: `task-next` → `task-finalize <task>` → `task-implement <task>`.
The ordinary Markdown task backlog and its dependency metadata remain supported.

Do not create `queued/`, launch an older runner directly from a pinned checkout,
or enable queue-driven CI repair. `run.sh` is a refusal stub for old entry points.
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

The execution discipline remains at [execution-discipline.md](execution-discipline.md)
for compatibility with consumers pinned to older task-implement guidance.

`self-terminate.sh` remains solely for the separate audit runner that links it.
It does not dispatch work.
