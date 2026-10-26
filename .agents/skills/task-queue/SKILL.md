---
name: task-queue
description: Explain that autonomous task execution is retired and direct work to the interactive task workflow.
---

# Task queue retired

Autonomous task execution is retired everywhere Workshop is adopted. Do not
launch a runner, promote tasks into `queued/`, or enable queue-driven CI repair.
Use `task-next` → `task-finalize <task>` → `task-implement <task>`.
Ready briefs belong in `finalized/`; active work belongs in `now/`.

The compatibility `run.sh` refuses every invocation without launching workers
or changing Git. See [the retirement and recovery guidance](README.md).
