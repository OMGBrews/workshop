---
name: task-implement
description: Implement a prepared task in the current session — re-verify the brief against HEAD, build to the acceptance criteria, tick them off as they are met, then close the task out on the user's confirmation (deleting the brief, per the repo's completion convention). Also the close-out path for a task that is already done but was never closed
---

# Implement Task

Take a prepared task and build it here, in this session, with the human
watching. This is the supervised middle of the pipeline: the `task-next` skill
recommends what to work on and offers `task-finalize`; `task-finalize`
verifies the brief and stamps `finalized-at`, and this skill executes it. The
autonomous task-queue runner does
the same job unattended, on the same discipline — see [Relationship to the
task-queue worker](#relationship-to-the-task-queue-worker).

**Arguments**: optional task filename (with or without `.md`) or
full path. If omitted, Phase 1 helps pick one.

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/` — written as `<tasks>/` below. If none exists, print "No tasks directory found — invoke the `task-create` skill to scaffold one." and stop.
- **Queue**: `<tasks>/queued/` (when it exists) belongs to the autonomous task-queue runner. Never pick from it — a task sitting there is already claimed, and implementing it here races a worker that may be mid-flight on the same brief. If the user names a queued task explicitly, say that and offer the `task-move` skill to pull it back into a human bucket first.
- **Definition of done**: `docs/work/definition-of-done.md` where it exists — the project-wide requirements that no individual brief restates.
- **The brief's vintage** is a commit, not a date: the commit that created the task file is `git log --diff-filter=A --format=%H --follow -- <task-file> | tail -1`. Window history with `<that-sha>..HEAD`, never with `--since=<date>` — commit dates aren't topology, so a branch merged after the brief was written carries commits dated before it, and a date window silently excludes exactly those.

## The shared execution discipline

**Read the `task-queue` skill's `execution-discipline.md` (`../task-queue/execution-discipline.md`) before Phase 3.**
Its five blocks are the discipline this skill runs on:

| Block | What it governs | Used in |
|-------|-----------------|---------|
| `staleness-check` | Diffing `finalized-at..HEAD` over the Scope paths; code wins over the brief; the acceptance criteria govern either way | Phase 3 |
| `recommended-solution` | Recommended solution is advisory, acceptance criteria are contract, deviations named in commit bodies | Phase 4 |
| `definition-of-done` | Finding `definition-of-done.md` and satisfying every applicable requirement | Phase 4, Phase 6 |
| `ac-sentinels` | Edits to the acceptance list stay inside `AC:BEGIN` / `AC:END` | Phase 4 |
| `ask-with-briefing` | Briefing the human before any question-prompt call | throughout |

That file is single-sourced because the task-queue worker runs on the same five
blocks — the runner expands them into the prompt it dispatches. It is written
in the worker's voice, so read it through the inversions below rather than
literally.

## Relationship to the task-queue worker

Same discipline, different setting: the worker is a fresh unattended session in
a runner-managed worktree, this skill is the human's own session. Four rules
invert, and only these four:

| # | The worker | This skill | Why |
|---|-----------|-----------|-----|
| 1 | Does not tick acceptance criteria — the runner deletes the whole brief | Ticks each criterion inside the sentinels as it is verifiably met | The human is watching progress in a file that stays on disk until the end |
| 2 | Never removes the brief; the runner runs `git rm` afterwards | Deletes the brief itself, in the completing commit — but only once the human confirms (Phase 6d) | There is no runner here to do it, and a human who can be asked should be the one to call it finished |
| 3 | Is forbidden final-state narration ("do not add a final state verification Bash call") | Closes with a report of what was implemented and how it was verified | The runner inspects the branch directly; a human cannot |
| 4 | Moves a blocked brief into `queued/blocked/` | Leaves it in its bucket with `status: blocked` and an appended `## Blocked` section | `queued/blocked/` exists in one repo only; the in-place shape is what the `session-land` and `task-status` skills read |

Two more differences follow from the setting rather than inverting a rule.
**Work happens in the current working tree**, not a worktree (Phase 4). And an
**unfinalized brief gets the full finalize-style verification inline**
(Phase 3) rather than the worker's lighter "treat its claims as unverified and
check them as you go" — the human is present to answer what the check turns up,
and 195 of the fleet's 199 tasks carry no stamp, so this is the ordinary case
rather than the edge.

Anywhere else the in-session flow would diverge from the worker's discipline,
**stop and record an open question on the brief** instead of inventing a rule.

---

## Phase 1 — Pick the task

If the argument resolves to a real task file under `<tasks>/{finalized,now,soon,later,never}/`, use it. Print the resolved path.

Otherwise, with no usable argument:

1. If the `task-next` skill exists in this repo (check the `.claude/skills/task-next/` bridge into the canonical `.agents/skills/` tree), stop and offer it: "No task named. Run `task-next` to pick one, then re-run `task-implement <task>`." Do not invoke it — the pipeline offers, it never chains.
2. Where that skill is absent, list `finalized/` first, then `now/` (falling back to `soon/` when both are empty), with each task's title, `effort`, `priority`, and acceptance-criteria progress, and ask which to implement. This is a pick-one capture, so a question prompt is appropriate — brief first, per the `ask-with-briefing` block.

Refuse a task whose `dependencies:` are unmet, naming the blocking task, unless the user overrides.

## Phase 2 — Screen, then claim

1. Record the session's starting commit: `git rev-parse HEAD`. Phase 6 needs it to prove work landed.
2. **Screen for open questions before claiming anything.** If the brief has a
   non-empty `## Open questions` section, stop here and write nothing: print the
   questions and recommend `task-finalize`. Do not resolve them — a design
   question answered unilaterally mid-implementation is exactly the decision that
   should have been the human's, and finalize is where it gets recorded.
3. Set `status: in-progress` in the brief's YAML frontmatter.

The screen precedes the claim deliberately. The original order claimed first and
refused in Phase 3, reverting the marker on the way out — so it wrote a marker it
was always going to undo, and an interruption inside that window leaves a false
`in-progress` on a task nobody touched: precisely the stale marker the `task-status` skill
exists to hunt. Refusing before writing removes the window rather than
documenting it. (Found by this skill's third live run, 2026-08-01.)

This skill is that field's first automated writer. The marker is deliberately
durable: a run that is interrupted — context exhausted, session closed, machine
slept — leaves it behind, and the `task-status` skill exists to find those. It clears
only two ways, both of them endings: completion deletes the whole brief
(Phase 6), and blocking rewrites it to `blocked` (Phase 5).

Commit nothing yet. The marker rides along with the first real commit.

## Phase 3 — Verify before writing code

A brief is a cache of code observations, and this phase is where the cache is
validated. **No implementation edit happens before it finishes.** Apply the
`staleness-check` block, tiered on what the frontmatter claims:

**Tier A — open questions present.** Screened in Phase 2, before the claim, so a
brief reaching this phase has none. If one turns up here anyway, the screen was
skipped: stop, print the questions, recommend `task-finalize`, and revert the
Phase 2 claim on the way out.

**Tier B — `finalized-at` present.** Run
`git log --oneline <finalized-at>..HEAD -- <the brief's Scope paths>` (whole
repo if the brief names no Scope). Empty output: trust the brief as written.
Non-empty: re-verify only what moved — read the commits, read the cited
constructs, and where brief and code disagree, the code wins.

The `staleness-check` block's tracked-path guard applies here in full: before
trusting an empty result, confirm this repo tracks the Scope paths with
`git ls-files --error-unmatch -- "$path"`, because `git log` prints nothing and
exits 0 for an untracked, gitignored, or foreign-repo path. This is routine, not
exotic: a brief whose Scope names a sibling clone or a submodule (hq's tasks name
`devtools/` paths, which hq gitignores) hits it every time. In this skill an
untracked Scope path demotes the task to **Tier C** for that path — do the
inline verification below rather than assuming the brief is current. That
demotion is the one part the shared block does not state, because the worker has
no tier ladder to demote into.

**Tier C — no `finalized-at`.** The dominant case. Run the finalize-style
verification inline before writing code:

1. Read every file the brief cites, in Context, Scope, and the recommended solution. Confirm each cited construct still exists; re-anchor by symbol plus a greppable quote where it moved.
2. Find the brief's vintage commit (see Repo conventions) and skim `git log --oneline <vintage>..HEAD -- <scoped paths>` for anything touching its claims.
3. Grep the absolute claims — "X is never assigned", "nothing checks Y", "the only caller of Z". Those are the ones that rot silently and the ones a single `grep -rn` settles.
4. Scale with `effort:` — for `medium`/`large`, fan an `Explore` subagent over the scoped subsystem so verification is not confined to the paths the possibly-stale brief happens to name.

**Then say what drifted**, before writing anything: a short block naming what
you checked, what was still true, what had moved, and which commits moved it.
"No drift found" is a valid and useful result — but it has to be stated, not
assumed. If verification shows the task **no longer applies**, stop and say so
rather than manufacturing work; offer the `task-audit` skill.

If it shows the task is **already done** — the work is in the tree, the criteria
are met, and only the brief was never closed — say so and go straight to
**Phase 6**. Do not manufacture work, and do not hand the state back as someone
else's problem: closing it is this skill's job. That is the same finished-but-not-
closed state the `task-status` skill reports and offers `task-implement` for; this is
where the offer lands.

If drift is large enough to change the design rather than just the anchors,
that is a finalize-shaped problem: stop and recommend `task-finalize`.

## Phase 4 — Implement

Work **in the current working tree**. Worktree isolation only when the user
explicitly asks for it, and then carefully: Claude Code's worktree management
has known bugs, and the task-queue runner's worktrees work only because
`run.sh` maintains a repo-specific shared-paths symlink list (`SHARED_PATHS`
plus `.task-queue-shared-paths`) that a skill body cannot reproduce — an
env-file or `node_modules` symlink this skill forgets is a test suite that
fails for reasons that have nothing to do with the task.

While building:

- **The acceptance criteria are the contract**; the `## Recommended solution` is advisory. Follow the recommended design unless the code at HEAD contradicts it, and when you deviate, say what you changed and why in the body of the relevant commit — never silently.
- **Tick each criterion as it is met**, editing strictly inside the `AC:BEGIN` / `AC:END` sentinels. Tick on evidence, not on intent: the change is made and you ran the thing that shows it works. An unticked criterion at the end of the run is information; a criterion ticked because it was attempted is a lie the next reader has no way to catch.
- **`- [~]` is a real state, and it is not done.** Live task files use three markers, not two: `- [ ]` not started, `- [x]` met, `- [~]` partially met — a hand-written signal that someone got part-way and stopped. Never promote a `[~]` to `[x]` on the strength of the earlier work; treat it as unmet and finish it, or leave it `[~]` and go to Phase 5. Whatever unusual marker a brief arrives with, preserve it rather than normalizing it away.
- **Satisfy `<tasks>/definition-of-done.md`** where it exists. The brief does not restate those requirements; they apply anyway.
- Commit in well-scoped commits as you go, following the repo's commit conventions.
- Fan out subagents for independent work, but keep `git` and the test runs to yourself — concurrent edits to disjoint files are safe, concurrent `git` in one tree is not.
- Ask when you need to, with the briefing the `ask-with-briefing` block requires. In a session where the human is at the keyboard, a plain-text question ending your turn is usually the right shape; the push-notification form is for when they have walked away.

## Phase 5 — Blocked

When the task genuinely cannot proceed — missing context you cannot recover, a
decision only the human can make, an undone prerequisite — do not delete the
brief and do not leave it silently half-done:

1. Append a `## Blocked` section naming the obstacle in one paragraph, with the file paths and commit SHAs that show it.
2. Set `status: blocked` in the frontmatter.
3. Leave the file in its current bucket.
4. Commit whatever partial work exists along with the brief edit, then stop and tell the user what is needed.

This is the same shape the `session-land` skill writes when it lands an interrupted
task, so the two are readable by the same eye and by the `task-status` skill. "Hard" is
not blocked — only "cannot proceed without input" is.

## Phase 6 — Complete

The worker's costliest failure was treating "end of turn" as completion. Here
the human supervises, so that specific bug cannot bite — but the discipline
behind the runner's `validate_worker_state` check is worth keeping anyway:
**do not accept your own "done".**

**Two ways in.** The usual one is Phase 4 finishing — the last criterion met,
loose ends tied up. The other is a task routed here from Phase 3 because it was
already done and never closed. Both run the same checks and the same
confirmation, and neither skips 6b: a task that *looks* finished is exactly the
one whose markers deserve enumerating.

### 6a — Self-distrust verification

Run all four before claiming completion. Each has an answer you can read, not one you assert:

| The runner checks | Check here |
|-------------------|-----------|
| The brief is gone from the worktree | **Not here — at 6e.** The deletion follows the human's confirmation, so this cannot be true yet; asserting it at 6a is a check nothing can pass. Here, confirm the inverse: the brief is still present, and removing it is the only change left |
| Commits exist beyond the branch's start SHA | `git log --oneline <Phase 2 SHA>..HEAD` is non-empty and the commits are this task's |
| No leftover `STUCK.md` | No scratch files, debug prints, or commented-out blocks left behind — read your own diff (`git diff <Phase 2 SHA>..HEAD`) |
| The tree still builds (`pytest --collect-only`) | The repo's cheapest whole-tree sanity check passes — test collection, a type check, a build, whichever this repo has — plus every applicable `definition-of-done.md` requirement |

### 6b — The acceptance requirement is `[x]`, not "no `[ ]` left"

Deletion is irreversible in the sense that matters — it is what tells every
later reader the work is finished. So verify it positively: **every marker inside
the `AC:BEGIN` / `AC:END` zone must be exactly `[x]`.** Enumerate them and read
the list; do not test for the absence of `- [ ]`.

That absence test is the decorative check `signal-hygiene.md` warns about, and
here it is actively destructive: `- [~]` (partially met) is in live use in this
fleet, always on a `status: in-progress` brief, and it contains no `[ ]` — so
"no `[ ]` remains" reports success on a task with unfinished criteria and the
next step deletes it. Any marker that is not `[x]` — `[ ]`, `[~]`, or anything
else someone wrote — blocks completion. Name each one and its criterion text,
then either finish it or take the Phase 5 blocked path.

Then re-read the criteria one at a time and confirm each `[x]` against the
diff. A criterion you cannot point at evidence for is not met: untick it and
either finish it or go to Phase 5.

### 6c — Check inbound links before deleting

Deleting a task file breaks links in files the diff never touches, which is why
the completing commit is the canonical generator of that breakage (observed
twice in one repo, 2026-07-23 and 2026-07-30). Before removing the brief:

```bash
grep -rn "<task-slug>" --exclude-dir=.git .
```

Every hit outside the task file itself is an inbound link. A README index entry
and a "see also" in another brief are the usual two. Sort them into two classes
before touching anything, because 6d treats them differently:

- **Broken by the deletion** — correct today, dangling once the brief is gone.
  Fix these *in the completing commit*, and only on a confirmed close-out. On a
  decline they are still correct, and "fixing" one deletes a working link.
- **Already wrong** — pointing at the wrong bucket or a renamed slug, broken
  before you arrived. These are not contingent on the deletion, so fix them
  either way. This class is not hypothetical: of the three hits in this skill's
  first live run, two were already pointing at the wrong bucket.

List both classes in the closing report, with which ones you actually changed.

### 6d — Ask before deleting

Everything above is a check you run. This is the one call you do not make alone.

Present what 6a–6c found — each criterion and the evidence behind it, the checks
that ran and what they printed, the inbound links you would fix — and then ask,
plainly, whether to close the task. Deleting the brief is what tells every later
reader the work is finished; the human is the one entitled to say that.

- **Confirmed** → 6e: delete the brief, with both classes of link fix, and
  commit them with the work.
- **Declined** → commit the implementation and any *already-wrong* link fixes
  *without* the deletion, leave the links that only the deletion would have
  broken exactly as they are, leave the brief in its bucket with
  `status: in-progress` (which is then simply true), and say what is
  outstanding. Never end a decline with a dirty tree — a half-committed refusal
  is worse than either answer. Where the work was already committed as it went,
  a decline is allowed to change no files at all; the report is the deliverable.

Ask by ending your turn with a plain-text question when the human is at the
keyboard: it fires no push notification and the answer is one word. Reserve
a question prompt for when they have walked away, and brief them first per the
`ask-with-briefing` block.

Do not ask this question early. An offer to close made before 6a–6c have run
asks the human to ratify checks that have not happened, and their "yes" will
look afterwards like it covered them.

### 6e — Delete the brief in the completing commit

Completed tasks are deleted, not archived; git preserves the history and
`git log --diff-filter=D` finds them. `git rm <tasks>/<bucket>/<task>.md` and
commit it together with the final implementation change and any link fixes, so
one commit shows the work and the brief's removal as the single event they are.

Before committing, read `git status --short` and confirm the brief shows `D`.
This is the runner's "the brief is gone" check, deferred from 6a to the one
point in the flow where it can be true.

**The brief's final state must already be committed before this commit removes
it.** Edit a file and delete it in the same commit and git records only the
deletion, whose diff shows the *parent's* content: the ticked criteria and the
evidence you wrote beside them then exist in no commit at all, and the history
that was supposed to preserve the finished brief preserves the unfinished one.
Phase 4's commit-as-you-go normally handles this. If the last criterion was
ticked without a commit, commit that first, then delete in a second commit —
two commits that keep the record beat one that reads well and loses it.

The `status: in-progress` marker disappears with the file. That is the only
clean way it goes away.

### 6f — Report

Close with a short block — this is inversion #3, and the whole reason it exists
is that the human cannot inspect a branch the way a runner can:

- The task, and the commits that implemented it.
- What Phase 3 verification found (what drifted, or "no drift").
- Each acceptance criterion and the evidence it was met by.
- Which checks ran and what they printed.
- Inbound links found and how each was handled.
- Anything deliberately left undone, and why.
