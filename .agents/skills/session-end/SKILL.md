---
name: session-end
description: End-of-session checklist — capture unrecorded kaizen friction, run safe workspace hygiene, and surface anything needing a human decision before the session closes. This skill hands the open pile TO the human and never auto-commits. Its deliberate opposite is session-land (same moment, opposite direction), which absorbs the pile, decides each item on the human's behalf as a labeled reversible recommendation, and does commit — reach for that one instead when the user is out of capacity to answer a checklist.
---

# End Session

Run at the end of a working session. The skill has two distinct jobs and keeps them separate:

1. **Kaizen Check** — make sure this session's friction got recorded before its context evaporates. The kaizen guide (`<this skill's physical directory>/../../../docs/kaizen-guide.md`, resolved by the physical-directory rule — [`skill-path-resolution.md`](../../../docs/skill-path-resolution.md)) names "context loss between sessions" as a seam where friction lives, and maps the PDCA **Check** stage to "capture friction when standards misfire." This skill is that checkpoint.
2. **Hygiene** — leave the workspace clean for the next session.

The skill **acts directly** on safe, unambiguous items and **surfaces** judgment items for the user rather than deciding them. It never pushes, never auto-commits.

Run the phases in order — Phase 2 (Kaizen Check) must happen *before* Phase 5 (cleanup), because cleanup can erase the evidence a journal entry needs.

This skill assumes the project has adopted kaizen (`docs/work/kaizen/` with `journal/` and `patterns/` under it). If it has not, invoke the `kaizen-init` skill first, or skip Phase 2.

## This is not `session-land`

Same moment in the session, opposite direction — pick deliberately. `session-end` **surfaces** the open pile *to* the user (Phase 6) and **never auto-commits**; [`session-land`](../session-land/SKILL.md) **absorbs** it, deciding each open item *for* the user as a labeled, reversible recommendation filed in a durable artifact, and **commits everything** — the documented override of this skill's no-auto-commit rule. Use `session-end` when the session ended normally and the user can still weigh a list of decisions. Use `session-land` when they cannot: it asks nothing, because a tired developer cannot answer a checklist either. Both skills refuse to push.

Three of this skill's phases are **duplicated verbatim** into `session-land` (see the sync markers on Phases 2, 3, and 5). That is deliberate — the two contexts may need subtly different text — so an edit here needs a hand-sync there.

---

## Phase 1 — Snapshot

Capture the session's end state before changing anything. Run these and hold the results for later phases:

- `git status --short` — uncommitted changes.
- `git log --oneline '@{push}..HEAD'` — unpushed commits. **Check the exit code.** `@{push}` is unset on a branch with no upstream and on a detached HEAD, and the command then exits non-zero while printing nothing — identical to what "no unpushed commits" looks like. If it fails, fall back to `git fetch origin && git log --oneline "origin/$(git rev-parse --abbrev-ref origin/HEAD | sed 's|origin/||')..HEAD"`; if *that* fails, report unpushed state as **unknown**, never as zero. Reporting "nothing outstanding" over real unpushed work is the exact failure this checklist exists to prevent (see [`signal-hygiene.md`](../../../docs/signal-hygiene.md)).
- `git worktree list` — active worktrees.
- Background processes this session may have started — background shells launched with a run-in-background option, spawned agent sessions (other CLI-harness runs this session launched that may still be running work), and any autonomous runner the project uses (e.g. a task-queue runner). Identify them; do not kill yet.
- Spawned teammates still alive (check team/agent state).
- Any scheduled wake-up timers or loop-mode background runs still pending.
- Current task state from the task list.

Print a one-line state summary. Do not act yet.

---

## Phase 2 — Kaizen Check

<!-- SYNC MARKER — the body of this phase is duplicated, deliberately, into
     ../session-land/SKILL.md (its Phase 4). Duplication rather than reference is the
     owner's call: the two contexts may need subtly different text, and a shared-skill
     refactor can come later if they stay identical. The prose is verbatim there; only
     the phase number and the sub-heading labels differ. Edit one, hand-sync the other. -->

**Do this before any cleanup.** Review the session for friction that should be journaled and isn't.

### 2a — Scan for unrecorded friction

Match the session against the kaizen guide's "when to write" triggers:

- Something took significantly longer than expected.
- A fix required multiple attempts.
- A convention should have existed earlier.
- An approach that seemed right turned out wrong.
- Orchestration or tooling caused friction.
- A pattern repeated for the third time.
- Something was reported as done on the strength of a check that never actually exercised the failing condition — or was never executed at all. (Backstop only; this pattern is meant to be caught mid-task by [`signal-hygiene.md`](../../../docs/signal-hygiene.md), not here at the end.)

Exclude things that already have a home: routine work that went smoothly (that's git history), anything already in a memory feedback file, and **friction already journaled earlier this session** — list today's entries before adding:

```bash
ls "docs/work/kaizen/journal/$(date +%Y-%m)/$(date +%Y-%m-%d)"-*.md 2>/dev/null
```

Remember the scope boundary: kaizen is about **how we build** (collaboration loops between humans, AI agents, tooling), not **what we build**. Feature ideas go to the project's planning/ideas area, never the journal.

### 2b — Write entries

Each piece of unrecorded friction becomes **its own file** at `docs/work/kaizen/journal/YYYY-MM/YYYY-MM-DD-<slug>.md` — create the month directory first (`mkdir -p`). The slug is the title lowercased with every run of non-alphanumeric characters replaced by a hyphen, capped at ~60 characters on a word boundary; if that filename is taken, append `-2`. Use the canonical format:

```markdown
# [short title]

**Context**: What we were trying to do
**What happened**: What we tried, what went wrong or right
**Friction**: Specific errors, delays, or confusion encountered
**Lesson**: What we learned; what to do differently
**Action**: Concrete change made or to be made (commit hash, task created, etc.)
```

The date lives in the filename, not in the heading, and entries take no frontmatter.

Name the **root cause**, not the symptom. Be concrete (exact tool, specific flag, what was expected vs. what happened). Make the **Lesson** load-bearing — phraseable as a one-line rule.

### 2c — Match against the live artifacts (light touch only)

Do **not** run a full `patterns/` review — the guide sets that cadence at "~2 weeks or after a sprint," not per-session, and the `kaizen-review` skill is the one that owns it. The only per-session matching action: if a new entry's root cause clearly matches a live kaizen artifact, note the match in the entry's **Action** field. Three sets to check, not one:

- **`docs/work/kaizen/patterns/`** — the entry is another instance of a known tendency; name the pattern file.
- **`docs/work/kaizen/singletons.md`** (where it exists) — the entry is the second instance a watch line has been waiting for. Note the match and stop: the `kaizen-review` skill is the watchlist's only writer, so never add, drop, or edit a line there — the next review routes the pair.
- **`docs/work/problems/`** (where it exists) — the entry is a fresh instance of a documented flaw. Link the problem document by relative path so the review can attach the entry as evidence.

Leave routing, clustering, and graduation for the periodic review.

Then check whether that review is overdue and carry the answer to the report — checking is not running it:

```bash
git log -1 --format='%cs %h %s' -- docs/work/kaizen/patterns/ docs/work/kaizen/singletons.md   # last review output
git log -1 --format='%cs %h %s' -- docs/work/kaizen/journal/                              # last entry written
```

Review output older than ~2 weeks with newer journal entries means the `kaizen-review` skill is due. Report both dates beside the verdict rather than asserting a review date: these are a proxy for one the repo does not keep. The proxy is stronger since the journal lifecycle landed — a review now writes a watch line for every entry it cannot cluster, so a review with a non-empty window almost always touches one of those two paths (the exception: a review whose only output was a problem document) — but an empty-window review still leaves no trace, and a `patterns/` edit outside a review refreshes the date without one having happened.

<!-- END SYNC MARKER (Phase 2) -->

---

## Phase 3 — Memory self-check

<!-- SYNC MARKER — duplicated, deliberately, into ../session-land/SKILL.md (its Phase 5).
     Verbatim; hand-sync on edit. See the note on Phase 2. -->

Consider — as your own judgment call, **not** a question to put to the user — whether any durable facts surfaced this session that belong in auto-memory: user preferences or working style, project state not derivable from code or git history, or gotchas worth persisting. Apply the memory-system rules (one fact per file, check for an existing file to update, don't save what the repo already records). Act on this directly and silently per those rules; do not prompt the user to direct memory.

<!-- END SYNC MARKER (Phase 3) -->

---

## Phase 4 — Docs drift (flag only)

If the session changed architecture, a feature's behavior, a convention, or a procedure, check whether the present-tense docs still match. **Flag** any divergence in the Phase 6 report; do not fix it here. The documentation quality sweep is the `audit-and-fix` skill — run it separately. It is deliberately not part of this skill.

One drift shape gets its own check: **a problem document describing a flaw this session fixed.** If the repo keeps `docs/work/problems/` and the session's work fixed — or plausibly fixed — a flaw one of those documents describes, flag that the `kaizen-resolve` skill may be due, naming the document. Flag only, never run it: the close-out deletes the document and the journal entries it consumed behind an evidence gate, and invoking that ritual is the user's call. The flag belongs *here*, at session end, because the close-out cascade falls to the session that verifies the flaw gone — this session holds the evidence, and that context evaporates when it closes.

---

## Phase 5 — Safe cleanup (act directly)

<!-- SYNC MARKER — the bullet list below is duplicated, deliberately, into
     ../session-land/SKILL.md (its Phase 7). Verbatim; hand-sync on edit.
     See the note on Phase 2. -->

Act on these without asking — they are unambiguous and reversible-by-nature:

- **Scratch files** — remove `/tmp` files (or similar) the session created for its own scratch use.
- **Stale tracking tasks** — delete session-scoped tracking tasks from the task list that were created for in-session progress tracking and are now moot. Do not delete tasks that represent real outstanding work.
- **Idle teammates** — shut down spawned teammates whose work is done.
- **Unchanged worktrees** — remove `isolation: "worktree"` worktrees that have no commits and no uncommitted changes. **Never remove a worktree owned by an autonomous runner** (e.g. a task-queue runner's worktrees) — those are infrastructure.

<!-- END SYNC MARKER (Phase 5) -->

---

## Phase 6 — Surface for the user (report, do not act)

Collect these into the Phase 7 report. **Do not act on them** — they need a human decision:

- **Uncommitted changes** — list them. Do not commit without an explicit instruction.
- **Unpushed commits** — list them. **Never push.**
- **Worktrees with uncommitted or unmerged work** — anything in `git worktree list` that isn't clean (and isn't an autonomous runner's).
- **If the project uses an autonomous queue runner** — flag any finalized work that's staged for it but not yet committed (the runner watches committed state, so uncommitted work is invisible to it).
- **Anything else** that needs a decision — doc drift or a `kaizen-resolve` flag from Phase 4, a pending loop-mode run, a half-finished task.

---

## Phase 7 — Report

Print a concise end-of-session summary:

- **Kaizen** — journal entries added this session (titles), or "no unrecorded friction."
- **Patterns review** — one line from Phase 2c: the two dates and whether the `kaizen-review` skill is due. Informational only — it never blocks the report and this skill never runs the review.
- **Memory** — what was saved, or "nothing durable."
- **Cleanup** — what was removed/shut down.
- **Needs your attention** — the Phase 6 list, each item one line. If empty, say "nothing outstanding."
- **Background** — note if any autonomous runner or background process is still active (informational, not a problem).

End there. Do not offer to commit, push, or schedule anything.

---

## Hard "do NOT" list

- **Do NOT push.** The user pushes manually.
- **Do NOT auto-commit.** Surface uncommitted work; let the user decide. The single documented exception is a *different* skill: [`session-land`](../session-land/SKILL.md) commits everything, labeled, because it runs when the user is not available to decide. Invoking that skill is how the user opts into the override — never do it from here.
- **Do NOT run full audits** — the `audit-and-fix` skill and other heavy audits are separate, not per-session.
- **Do NOT force a `patterns/` review** — that's the periodic Act stage, not per-session.
- **Do NOT write to `docs/work/kaizen/singletons.md`, `patterns/`, or `docs/work/problems/`** — the journal entry is the only kaizen artifact this skill writes. Matches are noted inside the entry (Phase 2c); a fixed flaw is flagged for the `kaizen-resolve` skill (Phase 4), never resolved here.
- **Do NOT touch an autonomous runner or its worktrees.** If the project runs one (e.g. a task-queue runner), it actively mutates the repo while you work; leaving it running is correct.
- **Do NOT prompt the user to direct memory** — the memory self-check (Phase 3) is your own call.
