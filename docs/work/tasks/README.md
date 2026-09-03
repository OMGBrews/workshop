# Tasks

This queue holds planned Workshop work. Create briefs with the shared `task-create` skill, then place them in the appropriate planning bucket.

- **`now/`** — Active work — in progress, or the next thing to pick up.
- **`soon/`** — Planned work that starts once current work clears.
- **`later/`** — Valuable work that is not yet scheduled.
- **`never/`** — Parked work that requires an explicit move to resume.

The definition of record for buckets is `.agents/skills/task-create/bucket-definitions.md`. Completed tasks are deleted; Git preserves their history.
