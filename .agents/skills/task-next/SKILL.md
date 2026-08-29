---
name: task-next
description: Fast pointer at the single next task — prefers finalized work, otherwise picks from now, soon, then later; screens only for blockers and weights by the focus document. Read-only, budgeted at ~4 tool calls.
metadata:
  latency: interactive
  model-hint: fastest-available
---

# Next Task

Answer "what should I work on right now?" for **this repository** — fast. Point at one
unblocked finalized task when available; otherwise use the highest-priority non-empty
planning bucket, weighted by what the focus document says matters. This skill is a quick pointer, not an audit: it trusts task
briefs as written and delegates verification to the skills that already do it —
`task-finalize` re-verifies the brief against HEAD as its own first step, and
`task-audit <task>` is the deep pre-flight for a brief you doubt.

It ranks by a deliberately small set of signals (below), not by the reprioritization
rubric. `task-reprioritize` owns the heavy ranking machinery and writes its judgment
into bucket placement; this skill *leans on* that placement instead of re-deriving it,
so it works best when a rebalance has run recently. Close enough is good enough here —
a fast, slightly imperfect pick beats a slow, perfect one, because the user can see the
queue too and will override a bad pick in seconds.

The [focus-document contract](../../../docs/focus-document.md) defines the file's
format and parsing rules. The selection-time staleness branches, lift, and demotion
below are this skill's deliberately lighter reader judgment.

**Read-only**: moves nothing, edits nothing, commits nothing, starts nothing. It ends
by *offering* the next command. Scope is this repository alone (`git rev-parse
--show-toplevel`); sibling projects' queues are never candidates.

**Arguments**: one optional free-form constraint in plain language ("30m", "tired",
"no Unity"). There is no flag grammar; read it the way a person would, fold it into the
pick, and echo back what it changed.

## Speed contract

The whole run is **at most ~4 tool calls**: one listing command, one batch read, at
most one tiebreak lookup. No codebase greps, no per-candidate git commands, no
subagents for analysis, no reading other skills or rubrics, no validation against HEAD.
If you are about to exceed the budget, stop gathering and present the best pick from
what you already have — say what you skipped.

The ranking is mechanical by design, so the smallest model available can run it. If
this harness offers a way to run this skill on a faster model than the current one —
per-skill model routing, delegating the whole procedure to a single subagent with a
faster-model override, a configuration hint the harness honors — use the fastest model
available. If no such mechanism exists, run inline in the current model; never spend a
tool call or a question discovering one. (The `model-hint: fastest-available` metadata
above is the machine-readable form of this request, for harnesses that read it.)

## Procedure

### 1. List (one call)

Tasks root: `docs/work/tasks/`. If none
exists, print "No tasks directory found — run `task-create` to scaffold one." and stop.

In one command: list `finalized/`, `now/`, `soon/`, and `later/`, and — if `focus.md` exists at the
tasks root — append `git log -1 --format=%cs -- <tasks>/focus.md` to the same command.

**Candidates are the `*.md` files in the first non-empty bucket**, in the order
`finalized/` → `now/` → `soon/` → `later/`. Exclude `README.md` and `_TEMPLATE.md`. `never/` is never
read; `queued/` (where it exists) belongs to the autonomous runner and is never read
either. A later bucket enters **only if** every candidate in the chosen one is screened
out in step 3 — say so when that happens ("`finalized/` is all blocked; picking from
`now/`" or "`now/` is all blocked; picking from `soon/`").

### 2. Read (one batch)

In one batch: the first ~40 lines of each candidate (enough for the frontmatter —
`status`, `effort`, `priority`, `dependencies` — plus the In brief and Goal), and all
of `focus.md` if present. A single `head -40` across the files is fine; parallel Read
calls are fine. Do not read candidates to the bottom and do not read losing buckets.

On focus.md staleness, branch on the git output from step 1: a date within ~30 days is
current; older, use it anyway and ask at the end whether it still holds; **empty output
means the file was never committed — report "staleness unknown", never treat it as
fresh**. No focus.md at all: say "no `focus.md` — ranking on mechanics alone" so a
mechanics-only pick is never mistaken for a focus-honoring one.

### 3. Screen

Drop only hard blockers, and name every dropped task with its blocker — never silently:

- `status: blocked` — quote the reason if the frontmatter or brief names one.
- A `dependencies:` entry naming a task that still sits unfinished in a bucket (you
  already have the listings from step 1 — no extra call).

That is the whole screen. No scope-path checks, no readiness tiers, no reading of
unchecked criteria. The user asked for a task with no dependencies that supports the
focus; deeper soundness is `task-finalize`'s job.

### 4. Rank

Apply in order; each rule only breaks ties left by the ones above:

1. **Resume beats start**: `status: in-progress` or any checked acceptance criteria →
   presumptive pick. (All criteria checked → not a candidate; report "looks finished —
   close it out with `task-implement <slug>`".)
2. **Focus**: focus.md's prose covers the task → lift it; its `**Not now:**` line
   covers it → sink it (but still show it as a runner-up with that reason).
3. **Explicit priority**: `high` nudges up, `low` nudges down. An untouched `medium`
   means "nobody set this", not "middling" — ignore it.
4. **Smaller `effort` first.**
5. **Still tied**: one `git log --diff-filter=A --follow --format=%aI` over just the
   tied files; older wins. Skip this call entirely when rules 1–4 already decided.

Fold the constraint argument in wherever it bites: a duration prefers small or
near-done work; fatigue prefers mechanical, well-specified work; an exclusion drops
matching tasks (shown with the constraint as the reason).

### 5. Present

```
## Start this: <title>

`<bucket>/<slug>.md` — <status>, effort <effort>, <X/Y criteria done>

<2-3 plain sentences: what it achieves and why it beats the others today. No jargon.>

Runners-up: <one line each, at most two>
Screened out: <task — blocker>            (only when something was dropped)
Focus: <one line: how focus.md shaped this, or "no focus.md — mechanics only">
Constraint: <what the argument changed>   (only when an argument was given)
```

Then one honesty line and one offer, and stop — never invoke anything:

- For a `finalized/` pick: "Finalized at `<sha>`; `task-implement <slug>` re-checks changes since that commit." Offer `task-implement <slug>` directly.
- For a planning-bucket pick: "Not validated against HEAD — `task-finalize <slug>` does that as its first step." Offer `task-audit <slug>` when the brief looks old enough to doubt.
- If focus.md was older than ~30 days: "`focus.md` was last touched <date> — is that
  still what matters?"

### When nothing is workable

An empty answer is a failed answer. All buckets empty: say so and offer `task-create`
(note how many tasks sit in `never/`, excluded by convention). Everything screened out
everywhere: list each task with its blocker in a short table; if some blocker is itself
a task in this repo, recommend *that* as the pick; if every blocker is external, say
the queue needs new work and offer `task-create`.

## See also

- [`../task-finalize/SKILL.md`](../task-finalize/SKILL.md) — verifies the pick against HEAD and resolves its open questions; the offered next step
- [`../task-audit/SKILL.md`](../task-audit/SKILL.md) — the deep pre-flight for a brief this skill deliberately did not validate
- [`../task-reprioritize/SKILL.md`](../task-reprioritize/SKILL.md) — the rebalancer whose bucket placement this skill trusts instead of re-ranking; run it when the buckets themselves feel wrong
