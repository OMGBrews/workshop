# Session return durability

**Scope**: A completed observational experiment (2026-07-29) on whether a Claude Code cloud session can reliably schedule its own return, plus a follow-up measurement (2026-07-30) of what arming that return *costs*. Records the question, the incident that prompted it, the tool inventory observed in a live cloud session, the observations and conclusion, and the prompt-cost side that decides the default. Read this before relying on a self-scheduled check-in in a skill.

## The question

`/ship` (`.agents/skills/ship/SKILL.md`) tells a session to arm its own return: after opening PRs, schedule a check-in so the session comes back and drives the work to merged rather than going idle forever. The whole Phase 7 hand-off rests on that return actually happening.

Three things have to be true for that to be sound:

1. A scheduled job, once created, **survives** until its fire time.
2. It **fires** into the session that created it, waking it.
3. A PR-activity subscription delivers the events that matter — specifically the **merge** event, not only CI results and review comments.

None of the three had been observed directly. This document settles them by observation.

## The 2026-07-29 incident

During a `/ship` run on 2026-07-29, a session scheduled a check-in and then, on a later turn, tried to clean it up. The deletion failed and the listing came back empty:

```
No scheduled job with id '...'
No scheduled jobs.
```

The job had silently disappeared. Two readings fit that evidence and the incident could not distinguish them:

- the job was never durably created (created in a store that did not outlive the turn), or
- the job was created, fired, and auto-deleted — and the later listing was simply looking at a *different* store than the one it was created in.

The second reading became plausible once this session found **two independent schedulers** with the same job-shaped vocabulary (below). A job created in one is invisible to the other, and both report absence with wording that reads as "it vanished."

## Step 1 — Tool inventory (observed 2026-07-29, cloud session, `claude-opus-5`)

Every scheduling / wake-up / notification tool actually available in this session, by exact name:

| Exact tool name | Kind | Durability (per its own schema) |
|-----------------|------|----------------------------------|
| `mcp__Claude_Code_Remote__send_later` | Schedule a message into **this** session at a future time | Server-side; "Delivery survives container restarts". Thin wrapper over `create_trigger` |
| `mcp__Claude_Code_Remote__create_trigger` | Create a Routine (scheduled trigger); can target this session, another session, or spawn a fresh one | Server-side, persistent |
| `mcp__Claude_Code_Remote__list_triggers` | List Routines owned by the account | Server-side |
| `mcp__Claude_Code_Remote__update_trigger` | Modify a Routine in place | Server-side |
| `mcp__Claude_Code_Remote__delete_trigger` | Delete a Routine | Server-side |
| `mcp__Claude_Code_Remote__fire_trigger` | Fire a Routine immediately, off-schedule | Server-side |
| `CronCreate` | Schedule a prompt via 5-field cron | **Session-only.** Its schema states: "Jobs live only in this Claude session — nothing is written to disk, and the job is gone when Claude exits." Its `durable` parameter "Has no effect — durable persistence is not available." |
| `CronList` | List cron jobs "scheduled via CronCreate **in this session**" | Session-only |
| `CronDelete` | Cancel a `CronCreate` job — "Removes it from the in-memory session store" | Session-only |
| `ScheduleWakeup` | Schedule the next iteration of a `/loop` run | Session-scoped; only meaningful inside `/loop` dynamic mode |
| `Monitor` | Stream events from a long-running script or WebSocket | Session-lifetime process, not a scheduler |
| `PushNotification` | Push a notification to the user's terminal/phone | Not a scheduler — notifies the human, does not wake the session |
| `mcp__github__subscribe_pr_activity` | Subscribe this session to GitHub activity on a PR | Server-side webhook delivery |
| `mcp__github__unsubscribe_pr_activity` | Cancel that subscription | Server-side |

### Does `send_later` exist?

**Yes.** `mcp__Claude_Code_Remote__send_later` exists in this cloud session and the `Claude_Code_Remote` MCP server is live — a read-only `mcp__Claude_Code_Remote__list_triggers` call returned real account data, so the server is connected, not merely declared.

This **contradicts** the local-machine evidence that motivated the experiment, which said `send_later` does not exist and only `CronCreate`/`CronList`/`CronDelete` do. Both halves of that local claim are wrong *here*: `send_later` exists **and** the Cron family exists. They are different systems, and this is the finding that most likely explains the incident.

### Two schedulers, one vocabulary — the trap

`CronCreate`/`CronList`/`CronDelete` and the `Claude_Code_Remote` Routine family are **separate, non-interoperating stores**:

- A job created with `send_later`/`create_trigger` is a server-side Routine. `CronList` does not see it and `CronDelete` cannot remove it.
- A job created with `CronCreate` lives only in this session's memory. `list_triggers` does not see it and `delete_trigger` cannot remove it.

So a session that schedules with one family and later cleans up with the other gets exactly the 2026-07-29 output — `No scheduled job with id '...'` followed by `No scheduled jobs.` — from a job that may be perfectly healthy in the other store. **The error message is indistinguishable from real loss.** Any skill that arms a return must name the family it used and clean up in the same family.

### What the trigger history already shows

`list_triggers` returned real historical Routines from this account, and their terminal states are themselves evidence:

- The 2026-07-29 job in question, `trig_01TGQSCN3rmwZA1gQqcVUKJY` (`send_later 2026-07-29T15:58Z #76fa58`), has `ended_reason: "run_once_fired"` and `last_fired_at: "2026-07-29T15:58:07.527442Z"`. **It fired.** It did not disappear. The failed lookup was looking in the wrong store.
- A separate Routine, `trig_015SATRRqDeroArrmfBqaecU`, carries `ended_reason: "auto_disabled_session_gone"` — a real, distinct failure mode: the Routine survived, but the session it was bound to did not, so it was disabled instead of delivered. Durability of the *job* is not the same as durability of the *return*.

## Observations

### What woke the session

**A PR-activity webhook merge event.** Not the scheduled check-in, and not a human prompt. The event arrived as a `<github-webhook-activity>` message reading, in part:

```
PR: OMGBrews/devtools#17
Outcome: merged
```

It also stated the session had been **automatically unsubscribed** on merge — no cleanup call was needed.

### Timeline (all times UTC, from `date -u` and API fields)

| Time | Event |
|------|-------|
| 19:10:21 | PR #17 opened |
| 19:10:33 | `send_later` Routine `trig_01Kbd6geBs7Qnk5nf6F1MGXz` created, `run_once_at: 2026-07-29T19:26:00Z` |
| ~19:10:4x | `CronCreate` one-shot `d1b1da5d` created (`29 19 29 7 *`); `subscribe_pr_activity` returned success |
| 19:12:29 | PR #17 **merged out of band** from the GitHub UI by `OMGBrewmaster` (`merged: true`, `merged_at: "2026-07-29T19:12:29Z"`) |
| ~19:12:3x | Merge webhook delivered; session woke |
| 19:12:37 | Wake time recorded by `date -u` |

**Webhook latency: roughly 8 seconds** from merge to session wake.

The merge beat the scheduled check-in by **13 minutes 23 seconds** (19:12:37 vs. the 19:26:00 fire time).

### Did the scheduled jobs survive?

Yes — both were alive and pending at wake, in their own families. `CronList`:

```
d1b1da5d — 29 19 29 7 * (one-shot) [session-only]: SESSION-RETURN-DURABILITY EXPERIMENT — session-only CronCreate check-in firing.…
```

`list_triggers` showed `trig_01Kbd6geBs7Qnk5nf6F1MGXz` with `"enabled": true`, `"next_run_at": "2026-07-29T19:26:00Z"`, no `ended_reason`, and `"persistent_session_id": "session_01Ukpo8chJSufHXxcuztKWHB"` — this session.

**Whether it would have fired is not observed.** The merge arrived first and the job was deleted during cleanup, before 19:26:00Z. Survival is confirmed; firing is not.

### The two-store separation, observed directly

While **both** jobs were live and pending simultaneously:

- `CronList` listed **only** `d1b1da5d` — the Routine was absent.
- `list_triggers` listed **only** `trig_01Kbd6geBs7Qnk5nf6F1MGXz` and older Routines — `d1b1da5d` was absent.

Neither family can see the other's jobs. This is observation, not inference.

### Deletion — in-family, then cross-family

In-family, both succeeded:

```
Cancelled job d1b1da5d.
```
```
deleted trigger trig_01Kbd6geBs7Qnk5nf6F1MGXz
```

Cross-family — passing the **Routine's** `trig_`-prefixed ID to `CronDelete`:

```
No scheduled job with id 'trig_01Kbd6geBs7Qnk5nf6F1MGXz'
```

and `CronList` immediately after:

```
No scheduled jobs.
```

**This is a byte-for-byte reproduction of the 2026-07-29 incident output.** The incident was a `trig_`-shaped ID handed to the session-only cron store. The job was never lost; the lookup was aimed at the wrong store.

Caveat, stated rather than glossed: by the time this cross-family call was made, the Routine had already been deleted in its own family, so this particular call cannot by itself distinguish "wrong store" from "already gone." The decisive evidence is the simultaneous cross-listing above, where both jobs were provably live and each family still showed only its own.

### MCP server connect/disconnect

- At session start, a system notice listed both `Claude_Code_Remote` and `github` as **still connecting**; their tools were not yet callable.
- `github` finished connecting mid-session and re-announced its full tool list.
- `Claude_Code_Remote` never re-announced, but was **live** — the first `list_triggers` call returned real account data. Its absence from the re-announcement is not evidence of a disconnect.
- **No mid-session disconnect or reconnect was observed** after both servers came up.

### Incidental observation: the subscription's own synthetic prompt

Subscribing immediately produced a synthetic `<github-webhook-activity>` turn instructing the session to poll CI and arm an hourly self-check-in. It contained this concession verbatim: *"webhooks don't reliably deliver CI success, new pushes, or merge-conflict transitions."* Note what that list does **not** include: the merge event. Consistent with what this run observed.

## The cost side — what arming the timer charges (measured 2026-07-30)

The experiment above priced the check-in's **benefit** and found it small: the subscription won
by over 13 minutes. It did not price the **cost**, and in a cloud session that cost is not
tokens or latency — it is **permission prompts on the maintainer's phone**. Every
`mcp__Claude_Code_Remote__send_later`, `delete_trigger`, and `add_repo` call is one.

Measured across a single `/ship` run (found-in-words-cms, 2026-07-30 — one code PR plus one
superproject pointer-bump PR, transcript under `~/.claude/projects/`):

| UTC | Call | Outcome |
|---|---|---|
| 02:14:39 | `send_later` (check-in on cms#153) | approved → trigger armed |
| 02:28:52 | `add_repo` (superproject) | approved |
| 02:32:21 | `delete_trigger` | approved — #153 already merged, timer moot |
| 02:33:10 | `send_later` (check-in on the superproject PR) | approved → trigger armed |
| 02:37:51 | `send_later` (same check-in again) | **rejected** |
| 02:42:56 | `delete_trigger` (duplicate cleanup) | **rejected**, then re-issued and approved |
| 02:43:36 | `add_repo` (superproject, again) | approved — returned `already_present`, a no-op |

Seven calls in twenty-nine minutes — eight prompts, counting the re-issued `delete_trigger` —
and **not one of them about the diff**. Three (02:14, 02:33, 02:43) are confirmed against the
maintainer's own phone log; the rest are read from the session transcript. Both PRs were merged
by hand within minutes of opening, so no timer ever fired usefully; the churn's only lasting
product was a stale Routine armed for 03:40Z that had to be cancelled by hand after the work
was done.

Three distinct wastes are visible in that table, and only the first is about the timer itself:

- **Redundant arming.** Two `send_later` calls behind two live subscriptions, on PRs a present
  maintainer was merging by hand.
- **Retry after a denial.** The rejected `send_later` was followed 70 seconds later by an
  equivalent one, and the rejected `delete_trigger` was re-issued verbatim. Neither rejection
  had any net effect — a denial that gets retried is just a delay.
- **Re-attaching an attached repo.** The second `add_repo` was issued blind after a context
  summary dropped the first one's result, and cost a prompt to return `already_present`.

### The asymmetry that decides the default

`send_later` can return `MCP error -32003: MCP tool call requires approval` (found-in-words-cms,
2026-07-29). That is not an intermittent fault — it is the tool's normal behavior when the
session lacks standing approval, and it means the call **completes only when a human acts on
it**. Put the two halves together:

- A session with a human reachable **can** arm the timer — and least needs it, because that
  human is the return path.
- A session with nobody reachable **needs** the timer — and cannot arm it at all.

The insurance is thus available exactly where it is redundant and unavailable exactly where it
would pay. Arming it reflexively buys close to nothing and charges a prompt each way: one to
arm, a second to cancel when the merge lands first.

### What this changes, and what it does not

Not the primary finding — the subscription is still the wake mechanism, on the 2026-07-29
numbers, and stays armed unconditionally. What changes is the fallback's **default**: arm the
check-in only when the subscription did not arm, which is the one case where the timer is a
sole return path rather than a duplicate of one. `/ship` Phase 5 step 5 states the rule; this
section is its evidence.

Two costs this measurement does **not** settle, so neither should be asserted: whether the
prompt for a `send_later` reaches a maintainer who is genuinely away (here it went unanswered
only when one was present and busy), and what a rejected prompt does to a session that has no
other return path armed. Both sit downstream of the caveat the 2026-07-29 run already left
open — whether a check-in scheduled hours out fires into a long-idle session at all.

## Conclusion

**(1) Did the scheduled check-in survive and fire?** It **survived** — confirmed alive, enabled, and correctly bound to this session at wake time. Whether it would have **fired** is **not observed**: the merge webhook beat it by over 13 minutes and the job was deleted in cleanup before its fire time. The 2026-07-29 disappearance, however, is **fully explained and reproduced** — it was a cross-store lookup, not a lost job. The incident's own Routine records `ended_reason: "run_once_fired"`. Nothing vanished. That said, `ended_reason: "auto_disabled_session_gone"` on another Routine shows a genuine way a scheduled return can fail to arrive: the job outlives the session it was bound to and is disabled undelivered.

**(2) Did the PR subscription deliver the MERGE event?** **Yes — decisively.** This is the strongest result of the run. An out-of-band merge from the GitHub UI woke the session in about 8 seconds, and the subscription auto-unsubscribed itself on merge. The merge event is not limited to CI results and review comments.

**(3) Is a self-scheduled return trustworthy enough for a skill to recommend?** **Yes, with two rules that this run shows are not optional.**

- **Name the family, and clean up in the same one.** This is the actual 2026-07-29 bug, and its symptom is a message that reads exactly like data loss. `send_later`/`create_trigger` pairs with `list_triggers`/`delete_trigger`. `CronCreate` pairs with `CronList`/`CronDelete`. Never cross them. Never conclude "the job vanished" from a single family's miss — check the other store before believing it.
- **Prefer `send_later` over `CronCreate` for anything that must outlive the turn.** `CronCreate` is explicitly in-memory and session-only; `send_later` is a server-side Routine that survives container restarts.
- **Arm it conditionally, not reflexively** — the third rule, added 2026-07-30 once the cost was measured. See below.

For `/ship` specifically: **the PR subscription — not the scheduled check-in — is the primary wake mechanism for a merge**, and it earned that on the numbers here. Arm it unconditionally.

The scheduled check-in is a different call. This run's own conclusion was "arm both, treat the timer as insurance" — that stood for one day and is **superseded**, because it priced only the benefit. With the cost measured ([the cost side](#the-cost-side--what-arming-the-timer-charges-measured-2026-07-30)), the rule is: **arm the check-in only when the subscription did not arm.** The reasons webhooks are imperfect are real — they are documented to miss CI success and new pushes, and a session-gone Routine can be disabled undelivered — but neither is repaired by a timer the session can arm only when a human is already reachable.

One caveat this run cannot retire: it observed a merge roughly two minutes after arming. It says nothing about a check-in scheduled hours out, or about whether a long-idle cloud session is still reachable when its Routine fires. That is the next experiment — and note that the conditional default narrows, rather than settles, the question: the timer now arms only in unattended sessions, which are exactly the ones whose reachability is unobserved.

## See also

- [`signal-hygiene.md`](signal-hygiene.md) — how to know a step actually happened; this experiment is an application of it
- [`ship`'s `SKILL.md`](../.agents/skills/ship/SKILL.md) — the skill whose Phase 7 hand-off depends on the answer
