# Ship reference — bringing a paused cloud session back

Loaded by the `ship` skill on a pull-request route in a cloud session, where
the session may pause with a PR open and needs a way back. The measurements
behind these rules are in Workshop's `docs/session-return-durability.md`.

## The subscription is the plan

Subscribe to every PR opened (`subscribe_pr_activity` on the GitHub MCP
server). A merge is delivered in seconds, with an automatic unsubscribe once it
lands. Review comments arrive the same way.

Do not extend that to CI. The subscription's own confirmation says webhooks do
not reliably deliver CI success, new pushes, or merge-conflict transitions. Read
check state directly (`pull_request_read`, or `gh pr checks`) before merging.

## The timer is not the backstop

`send_later` on the claude-code-remote MCP server can arm a server-side
check-in that outlives the turn. It can also return
`MCP error -32003: MCP tool call requires approval`, which is not a transient
fault: the call completes only if a human acts on it. So a session with
someone reachable can arm it and least needs it, and a session with nobody
reachable needs it and cannot arm it. Every call is a permission prompt on the
maintainer's device, both to arm and later to cancel.

Arm a timer only when **the subscription is not the return path**: the
subscribe call errored, is absent from the tool list, or did not confirm. One
timer per ship, never per PR. A rejected or errored scheduling call ends the
attempt; do not re-issue it with equivalent arguments.

## Two schedulers that cannot see each other

| Family | Arm | List | Cancel | Scope |
|---|---|---|---|---|
| Server-side Routines | `send_later` (also `create_trigger`) | `list_triggers` | `delete_trigger` | outlives the turn |
| Session-only cron | `CronCreate` | `CronList` | `CronDelete` | this session |

Arm and cancel in the same family, always. A `trig_…` ID handed to
`CronDelete` returns "not found" from a perfectly healthy job, and that answer
is indistinguishable from real loss. Read a "not found" as a question about
which store you queried before reading it as a failure.

Cancel the timer when the work it insured is over, merged or abandoned,
without being asked. Do not re-issue a `delete_trigger` the maintainer
declined; record the live trigger's ID in the report instead. Do not go
looking for a timer when the conditional rule armed none.

## Say it in the report

Name what is armed: subscription, timer, both, or neither. If the subscription
is the only path and it drops, this session will not wake itself; say so. Never
fall back to `CronCreate` as if it were equivalent, since it dies with the
session, and never make the merge step reachable **only** through a wake-up:
open PRs persist, and a later session runs `ship merge`.
