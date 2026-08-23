---
name: session-land
description: Land a long or complicated session on request — absorb every open decision instead of handing it back, file each one as a durable artifact carrying a labeled, reversible recommendation, and leave the tree committed with the single next action recorded as a resume point in the task document it belongs to. The deliberate opposite of session-end (same moment, opposite direction) — session-end surfaces open questions for the human and never auto-commits, session-land decides them on the human's behalf and commits. Invoke when the user says they are done, are tired, cannot decide any more, want to stop here, want this sorted out, or want to start fresh tomorrow. ALSO OFFER IT UNASKED after two or more distinct fatigue signals in one session — the signals, and the rules for offering without naming the person's state, are in this skill's "When to offer this unasked" section.
---

# Land Session

Run when a session must end and the developer no longer has the capacity to decide.
A long session accumulates open questions faster than it closes them; stopping while
they live only in the conversation means tomorrow starts by reconstructing yesterday.
This skill **absorbs** that pile: every remaining ambiguity becomes a decision made on
the developer's behalf, written into a durable artifact, labeled as a reversible
recommendation, and committed.

## When to offer this unasked

Normally the user invokes it. But **offer it unprompted after two or more distinct
fatigue signals in one session**:

- asking for a summary of items listed a message or two earlier;
- re-requesting an explanation already given;
- deferring rather than deciding ("we don't need to fix that right now");
- reversing a choice just made while also forgetting a stated detail.

Each signal is innocent alone. The combination, and its direction over the session, are
the signal. Offer **at most once per session**, action-framed — "this is getting
complicated — want me to land it so tomorrow starts fresh?" — **never** naming or
diagnosing the person's state, and a no ends it for the session.

## This is not `session-end`

Same moment in the session, opposite direction. Pick deliberately:

| | [`session-end`](../session-end/SKILL.md) | `session-land` (this skill) |
|---|---|---|
| Open questions | **Surfaces** them *to* the human to decide | **Absorbs** them — decides each one *for* the human, labeled and reversible |
| Asks the user | Yes — its Phase 6 is a decision list | **Never.** Asking nothing is its defining property |
| Uncommitted work | Lists it; **hard rule: do NOT auto-commit** | **Commits it, labeled.** This skill is the documented override of that rule |
| Ends with | A list of things needing your attention | A list of calls already made, and one next action |
| Use it when | The session ended normally and you can still think | You are out of capacity, or the session got complicated |

The commit inversion is the sharpest difference and is deliberate. `session-end` leaves
uncommitted work for the human because the human is available. Here the human is not, and
uncommitted work is the thing that evaporates overnight — so it gets committed. Pushing
stays out of scope in both skills.

## The one rule — ask nothing

Not "fewer questions". **None.** A developer who could answer a question would not have
invoked this skill, and a checklist is a question in list form. So:

- Do not use a user-question prompt. Do not print a confirmation prompt, an options menu, or
  "should I…?". Do not end a section with a question mark aimed at the user.
- Every ambiguity becomes a **stated, reversible recommendation** instead — the call, its
  one-line reasoning, and where to reverse it.
- Before printing the final report, re-read your own output hunting for questions. A
  non-rhetorical question mark addressed to the user means the skill failed.

The one exception lives *outside* the skill: the unprompted offer in this skill's
`description` is a question, asked before invocation. Once invoked, nothing asks.

Reversibility is what makes deciding for someone else safe. Nothing this skill does may be
irreversible: no pushes, no deploys, no releases, no destructive git, no `rm` outside the
session's own scratch files. Anything needing approval, credentials, or production access
is **recorded as a task, never attempted**.

Run the phases in order. Phase 4 (Kaizen check) must precede Phase 7 (cleanup), because
cleanup can erase the evidence a journal entry needs, and Phase 8 (commit) comes last
because everything before it writes files.

---

## Phase 1 — Inventory the open pile

Completeness here is the whole job — a missed item is the failure this skill exists to
prevent. Sweep both the conversation and the tree:

**From the session**, re-read it from the top and collect: every question you asked that
never got an answer; every "let's decide that later" or "we don't need to fix that right
now"; every fork you presented as X-or-Y; every item you listed as outstanding; every
correction the user made to your understanding; anything you promised to do and did not.

**This half is best-effort, and say so in the report.** "Re-read it from the top" is not
always available: a compacted or very long session is exactly the session this skill is
written for, and in one you are reading a summary rather than the transcript. Sweep what
you can reach, then name the limit in Phase 9's **Left alive** line ("the session was
compacted; the conversation sweep covers only what survived it") rather than presenting a
partial inventory as a complete one. The tree half below has no such gap — it is
mechanical and holds regardless, which is why a thin conversation sweep is a reason to
lean harder on it, not a reason to stop.

**From the tree**, mechanically:

```bash
git status --short                                   # uncommitted work
git diff --name-only HEAD                            # files this session touched
git log --oneline -20                                # what already landed
```

Then grep the touched files for `TODO`, `FIXME`, `XXX`, and read any `## Open questions`
section you edited this session. In a repo with a tasks directory, list every task whose
frontmatter says `status: in-progress`.

Print the inventory as a numbered list, then move straight into Phase 2 — the list is
printed for the record, never handed over. Do not pause on it, do not invite the user to
prune it, and do not decide anything yet; seeing the whole pile first is what keeps the
Phase 2 calls consistent with each other.

---

## Phase 2 — Decide every item, and label the call

Work the numbered list. Each item gets a decision *and* a home. Route by shape:

| The open item | Where it lands |
|---|---|
| Real work that must happen, but not now | A new task file in `<tasks>/` (bucket by urgency), with the call written into its Recommended solution |
| A decision that belongs to an existing task | That task's `## Decisions` (format `- **Q: <question>** — <answer>`) or Recommended solution |
| A decision that is blocking a task but is not really part of it | Its own task — see Phase 3 |
| Friction in *how we work* | A kaizen journal entry — Phase 4 |
| A durable fact about the user or the project | Auto-memory — Phase 5 |
| A design choice about a documented system | The doc it belongs to, stated as a recommendation with its reasoning |
| Anything needing approval, credentials, or production access | A task that names the operator step explicitly. **Do not attempt it** |
| An idea, not yet work | The repo's thought inbox (`docs/work/thoughts/` if it exists) — else a `later/` task |

Label every call so the morning can find and overturn them. Write the marker line into the
artifact itself, not just the report:

```markdown
> **Landed call** — <what was decided>, because <one-line reasoning>. Reverse by <the
> specific edit or move that undoes it>.
```

`grep -rn "Landed call"` then finds every decision made on the user's behalf. Keep the
reasoning to one line: the point is that overturning it costs a sentence of reading, not a
reconstruction. Do not stamp a date — git records when the file changed.

Two constraints on the calls themselves:

- **Prefer the reversible option**, even when it is not the option you would argue for
  with a rested developer in the room. A recorded recommendation costs a paragraph to
  overturn; work done on a wrong call costs a session.
- **Decide on paper, do not silently do the work.** Resolving a design question by
  implementing it and not saying so is the failure mode this skill is most likely to
  produce.

---

## Phase 3 — Split blocked work out of blocking tasks

A task stalled on a decision that is not really part of it stays stalled forever. Move the
decision into its own task, and the original becomes closeable:

1. Create the new task from the canonical template, `../task-create/_TEMPLATE.md` — the
   file next to this skill's sibling, resolved from this skill's physical directory per
   [`skill-path-resolution.md`](../../../docs/skill-path-resolution.md) — scoped to the
   decision alone, carrying the Landed-call recommendation from Phase 2.
2. Edit the original to reference it and drop the dependency, so what remains is
   completable work.

**Leave task frontmatter truthful.** The `task-status` skill's morning verdict pass reads it, and a
dangling marker turns that pass amber for no reason:

- A task interrupted mid-flight gets `status: blocked` plus an appended `## Blocked`
  section naming the obstacle with paths and commits — the same shape the `task-implement` skill
  writes. Never leave a dangling `status: in-progress`.
- A task nothing is actively working goes back to `status: not-started`.
- **Landing is not completing.** Do not tick acceptance criteria that were not verifiably
  met, and never delete a task brief during a landing.

---

## Phase 4 — Kaizen check

<!-- SYNC MARKER — the body of this phase is duplicated, deliberately, from
     ../session-end/SKILL.md (its Phase 2). Duplication rather than reference is the
     owner's call: the two contexts may need subtly different text, and a shared-skill
     refactor can come later if they stay identical. The prose below is verbatim; only
     the phase number and the sub-heading labels differ. Edit one, hand-sync the other. -->

**Do this before any cleanup.** Review the session for friction that should be journaled and isn't.

### 4a — Scan for unrecorded friction

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

### 4b — Write entries

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

### 4c — Match against the live artifacts (light touch only)

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

<!-- END SYNC MARKER (Phase 4) -->

A repo that has not adopted kaizen (`docs/work/kaizen/` absent) skips this phase — note the skip
in the report; do not invoke the `kaizen-init` skill during a landing.

One more landing-specific check, this skill's counterpart to `session-end`'s flag-only
version: if the repo keeps `docs/work/problems/` and the session's work fixed — or plausibly
fixed — a flaw one of those documents describes, do **not** invoke the `kaizen-resolve` skill and do
not delete anything. Record the close-out as its own task (Phase 2's routing), **quoting
the evidence that the flaw looks gone** — paths, commits, what was observed. That evidence
is what evaporates with the session, and it is exactly what the morning's `kaizen-resolve`
run will need at its evidence gate; a task that merely says "close out the problem doc"
lands nothing.

---

## Phase 5 — Memory self-check

<!-- SYNC MARKER — duplicated, deliberately, from ../session-end/SKILL.md (its Phase 3).
     Verbatim; hand-sync on edit. See the note on Phase 4. -->

Consider — as your own judgment call, **not** a question to put to the user — whether any durable facts surfaced this session that belong in auto-memory: user preferences or working style, project state not derivable from code or git history, or gotchas worth persisting. Apply the memory-system rules (one fact per file, check for an existing file to update, don't save what the repo already records). Act on this directly and silently per those rules; do not prompt the user to direct memory.

<!-- END SYNC MARKER (Phase 5) -->

---

## Phase 6 — Leave one obvious entry point

A fresh session should know where to start without recall. Programmers take roughly 10–15
minutes to resume after an interruption, and a note-to-future-self naming the next *edit*
is the measured countermeasure (Parnin, "Programmer, Interrupted") — so the landing writes
that note down.

**It goes in the task document, not in `focus.md`.** The resume point belongs where the
rest of that task's context already lives, and the `task-next` skill pins in-flight work ahead of
anything new (its Phase 4, in-flight pinning), so the morning reaches it through the queue
rather than through a pointer kept in a second file. `focus.md` states the repo's
*direction* and deliberately does not name a next task — the rubric's
[Direction, not a next task](../task-reprioritize/ranking-rubric.md#direction-not-a-next-task)
records why the `**Next action:**` line it used to carry was removed. **Do not write one,
and do not restore one you find missing.**

Where the resume point goes:

1. **The task document the work belongs to** — the brief for whatever was in flight, in
   its `<tasks>` directory (`docs/work/tasks/`). Write a
   `## Resume point` section, or replace the existing one: one unwrapped line naming the
   file and the next edit — concrete enough to start on, not "continue the migration".
   Leave `status: in-progress` in place and tick nothing; landing is not completing.
2. **No task document** because the session's work was never a task — file one (Phase 5
   already governs that) and write the resume point into it.
3. **No tasks directory at all** → the project's orienting document, the goal or plan doc
   its `CLAUDE.md` points at for current work, and name that choice in the report.

`focus.md` is touched by this phase in exactly one case: the session **changed the repo's
direction** — a new area of concentration, or something newly deprioritized. Then update
the prose, or the `**Not now:**` line, to say so, and label it as a landed call like any
other decision. Its format is **not this skill's to invent**; it has one specification, in
[`ranking-rubric.md`](../task-reprioritize/ranking-rubric.md#focus-weighting-tasksfocusmd).
Honor it exactly:

- **No dates anywhere in the file** — staleness is derived from git, and a written date
  goes stale the moment the prose around it is edited.
- **Replace the `**Not now:**` line in place** if one exists; insert at most one. Never a
  second copy.
- **Do not clobber the owner's prose.** Rewriting their statement of direction is a
  decision about what the repo is for, which is further than a landing reaches — add to it
  or leave it.

Only when creating the file from scratch, use the rubric's template: the heading, one to
five sentences on what the repo is concentrating on and why, and an optional `**Not now:**`
line naming what is deliberately deferred so the morning does not re-litigate it.

---

## Phase 7 — Safe cleanup

<!-- SYNC MARKER — duplicated, deliberately, from ../session-end/SKILL.md (its Phase 5,
     "Safe cleanup"). Verbatim; hand-sync on edit. See the note on Phase 4. -->

Act on these without asking — they are unambiguous and reversible-by-nature:

- **Scratch files** — remove `/tmp` files (or similar) the session created for its own scratch use.
- **Stale tracking tasks** — delete session-scoped tracking tasks from the task list that were created for in-session progress tracking and are now moot. Do not delete tasks that represent real outstanding work.
- **Idle teammates** — shut down spawned teammates whose work is done.
- **Unchanged worktrees** — remove `isolation: "worktree"` worktrees that have no commits and no uncommitted changes. **Never remove a worktree owned by an autonomous runner** (e.g. a task-queue runner's worktrees) — those are infrastructure.

<!-- END SYNC MARKER (Phase 7) -->

Also stop background processes this session started (background shells, spawned sessions,
pending loop-mode runs) — but **never** an autonomous runner such as a task-queue worker;
those are infrastructure and leaving them running is correct. Report anything left alive.

---

## Phase 8 — Land the tree clean

This is the documented override of `session-end`'s "do NOT auto-commit" rule. Commit
everything; push nothing.

- **Stay on the current branch.** Do not create or switch branches: work the user will look
  for in the morning must be where they left it. Local commits are reversible; a relocated
  branch is a scavenger hunt.
- **Never `git add -A` sight-unseen.** Read `git status --short` and add explicit paths, in
  logical groups. Anything that looks like a credential, a large binary, or another
  session's stray output does not get committed — leave it and name it in the report.
- **Half-finished work still gets committed**, labeled as such. Do not try to finish it:

  ```
  wip(<area>): <what is half-finished>

  Landed by the session-land skill. Unfinished: <what remains>.
  Resume point: <file and the next edit>.
  ```

- **Multi-repo checkouts** (submodules, or a workspace of clones): commit child-first, then
  the parent's pointer, and only for edges the parent already tracks. Publication —
  `push.sh`, the `ship` skill, any PR — is the user's call, not a landing's.

Verify by reading the commands' own signals, never by asserting the outcome
([`signal-hygiene.md`](../../../docs/signal-hygiene.md)):

```bash
git add <explicit paths>
git commit -m "<message>"     # read the exit code AND the summary line it prints
git status --short            # empty output is the verification that the tree is clean
```

If a commit hook fails, read its output. Fix only what is mechanical (formatter, lint
autofix) and commit again. **Never bypass a failing gate with `--no-verify`**: a real
failure becomes an open item in the task document's resume point, that change stays
uncommitted, and the report
names it as the one thing that could not be landed. A tree that is not fully clean is
reportable, not concealable.

---

## Phase 9 — Report

Short, skimmable, and honest about what was verified. In this order:

- **Landed calls** — every decision made on the user's behalf, one line each: the call,
  the artifact it was written into (with path), and how to reverse it. This is the section
  the morning reads first.
- **Filed** — new or updated artifacts, by path: tasks created or split, docs edited,
  kaizen entries added.
- **Corrections** — anything established during the session that contradicts something said
  earlier, re-stated plainly so an error does not survive as tomorrow's assumption.
- **Tree** — the commits made (SHA and subject), and what `git status --short` printed
  afterwards. Say the work is committed and **not pushed**. Do not report a
  remote-relative count unless you fetched first — `origin/main` is a cached snapshot, not
  the remote.
- **Resume point** — the line now in the task document, plus that document's path. Say
  plainly if the session changed `focus.md`'s direction, and if it did not.
- **Kaizen / Memory / Cleanup** — one line each, or "nothing". The kaizen line also carries Phase 4c's two dates as a **statement of state** — review output (`patterns/` + `singletons.md`) last changed X, journal Y — not as a suggestion to run the `kaizen-review` skill. Proposing the next piece of work is out of scope for a landing; recording where the repo stands is not.
- **Left alive** — background processes or runners still going, and anything that could not
  be landed.

End there. Do not ask a follow-up question, do not offer to push, and do not propose the
next piece of work.

**When another skill invoked you, "end there" ends the landing, not the session.** A
caller with its own closing gate — the `task-implement` skill's Phase 6d confirmation is the live
case — is not overridden by this rule: the landing is a step that supplies evidence, and
the caller's gate is the session's terminal act. Finish the report, ask nothing yourself,
and hand control back so the caller can put its own question. The rule forbids *this
skill* from asking; it does not forbid the skill that called it, and it never licenses
skipping a caller's confirmation because the landing "already ended".

---

## Hard "do NOT" list

- **Do NOT ask the user anything.** No user-question prompts, no confirmation prompts, no
  option menus, no trailing "want me to…?". This is the skill's defining property.
- **Do NOT push, deploy, release, or publish.** Committing is in scope; publication is not.
- **Do NOT do anything irreversible** — no `git reset --hard`, no history rewriting, no
  branch deletion, no `--no-verify`, no `rm` beyond the session's own scratch files.
- **Do NOT attempt anything needing approval or credentials.** Record it as an operator step.
- **Do NOT resolve a design question by silently implementing it.** Decide on paper, label
  the call.
- **Do NOT leave a dangling `status: in-progress`,** and do not delete a task brief —
  landing is not completing.
- **Do NOT claim a step happened without reading its exit code and output.** A landing that
  reports a clean tree it never verified is worse than one that reports the mess.
- **Do NOT run full audits** — the `audit-and-fix` skill and similar are separate and heavy.
- **Do NOT touch an autonomous runner or its worktrees.**

## See also

- [`session-end`](../session-end/SKILL.md) — the opposite-direction sibling; read the
  contrast table above before choosing between them.
- [`signal-hygiene.md`](../../../docs/signal-hygiene.md) — why this skill verifies its
  commits by reading them rather than by asserting them.
- [`kaizen-guide.md`](../../../docs/kaizen-guide.md) — the practice behind Phase 4.
- [`ranking-rubric.md`](../task-reprioritize/ranking-rubric.md#focus-weighting-tasksfocusmd)
  — the single specification of `focus.md`, which this skill writes only when the session
  changed the repo's direction. Its
  [Direction, not a next task](../task-reprioritize/ranking-rubric.md#direction-not-a-next-task)
  section is why Phase 6 puts the resume point in the task document instead.
