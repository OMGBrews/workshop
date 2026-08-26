---
name: task-finalize
description: Verify the given task against HEAD, orient the user before anything is asked of them, resolve its open questions interactively, write the recommended solution, and validate readiness. Requires a task name or path — it never picks a task itself.
---

# Finalize Task

Prepare a task for execution by a later session: verify the task's claims against the codebase at HEAD, sketch the intended approach and red-team it with isolated subagents, bring the user back up to speed before anything is asked of them, settle its open questions one at a time in conversation, record the resolutions in a `## Decisions` section, write a `## Recommended solution` where the analysis determines one, and validate the task against the readiness rules.

**Run this on the strongest model available.** Finalization is the moment it earns its keep: this skill locks in the decisions and the design a later implementer will execute, and a weak call here is inherited by every session that picks the task up. If you are on a weaker model, say so and offer to switch before Phase 3.

**Arguments**: a task filename (with or without `.md`) or full path — **required**. This skill finalizes the task it is pointed at; it never picks one.

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/` — written as `<tasks>/` below. If none exists, print "No tasks directory found — invoke the `task-create` skill to scaffold one." and stop.

Finalization's deliverable is a task verified, decided, stamped, and moved into `<tasks>/finalized/`. The move happens only after the readiness check passes. This skill edits and stages files, ends with a commit offer, and **never pushes** — synchronizing git with the remote is the user's, outside this skill. The run's classification decides the offer's shape:

- **Self-contained run** — everything *this run* put in the diff was already shown to and confirmed by the user through the Phase 5 discussion — each decision restated as a `**Recording:**` line before the next question opened — or is machine-derived (the `finalized-at:` stamp). Phase 9 offers the commit directly, disclosing any pre-run edits of the user's own (Phase 1 snapshots them).
- **Authored-content run** — the skill also created or substantially wrote content the user didn't see verbatim: follow-up task files spun off from a decision (Phase 5b), a drift-corrected `## Context` or `## Scope` (Phase 3), a brief defect fixed on the solution review's evidence (Phase 4a), a `## Recommended solution` (Phase 7), an `**In brief**:` paragraph (Phase 8), multi-paragraph prose. Phase 9 still offers the commit, but points the user at the staged diff for an IDE review first — the authored content is never pasted into the conversation.

Phases 3, 4a, 5b, 7, and 8 flag the edits that make a run authored-content as they happen; Phase 9 confirms the classification from the staged diff rather than from memory.

---

## Phase 1 — Resolve the Task

**The task argument is required.** Resolve it against `<tasks>/{now,soon,later,finalized,never}/`, accepting a bare name (with or without `.md`) or a path. Refuse a task under `queued/`: the autonomous runner may already own it, so moving it would race live work. Tell the user to use `task-move` to pull it back first.

One match → use it, printing the resolved path before continuing. Anything else — no argument, no match, or several — stop and say which it was.

Then snapshot the file's pre-run state: `git status --porcelain -- <task-file>`, plus `git diff HEAD -- <task-file>` when it reports modifications — diff against `HEAD`, not the index, so pre-run edits the user already staged are captured too. (Untracked is its own case: the whole document is pre-run content, but git records no pre-image for it, so Phase 9 classifies that start by its own rule.) This run's edits will land on top, and no after-the-fact diff can separate the two, so this snapshot is the only record of what the user brought to the run. It decides nothing here; Phase 9 reads it — to keep the user's pre-run hunks from reclassifying the run, and to disclose them in the commit offer.

---

## Phase 2 — Parse the Task

Read the task file end-to-end. Identify:

- The `## Open questions` block (may be absent, empty, or contain free-form content).
- Existing `## Decisions` section, if any (we'll append to it rather than duplicating).
- The YAML frontmatter fields: `status`, `effort`, `priority`, `dependencies`.

Extract individual **open questions** from the Open questions section as best you can. The section is free-form, so be flexible:

- Bullet/numbered list items → one question per item.
- Paragraphs separated by blank lines → one question per paragraph.
- A single block of prose with multiple `?` → split sensibly.
- HTML comments (`<!-- ... -->`) are guidance, not real questions — skip them.

While parsing, resolve the bundled checker from this skill's **physical** directory, so a project-level `.agents/skills/task-finalize` or `.claude/skills/task-finalize` symlink never makes it inspect the `devtools/` worktree:

```bash
skill_dir="$(cd -P "$(dirname "$(readlink -f .agents/skills/task-finalize/SKILL.md)")" && pwd)"
checker="$skill_dir/check-task-readiness.sh"
readiness_rc=0
readiness_output="$(bash "$checker" "$task_file")" || readiness_rc=$?
printf '%s\n' "$readiness_output"
printf 'EXIT=%s\n' "$readiness_rc"
```

Read the checker's numbered `FAIL` and `WARN` records as the structural agenda. Exit 1 is expected at this point: open questions or the not-yet-written `finalized-at:` stamp are normal pre-finalization failures, not a reason to skip the interview. Exit 2 is a usage or repository-context error; stop and fix that before continuing. Structural gaps the checker reports — a placeholder Goal, no real acceptance criteria, empty stopping conditions — join the interview agenda (assembled in Phase 4a, settled in Phase 5), so they surface before the interview instead of as failures after it.

---

## Phase 3 — Verify the task against HEAD

The task document is a **cache of code observations made at some past commit**, and the codebase has moved since. Resolving open questions from the document's own premises risks locking in decisions against a stale worldview — and handing on a brief that instructs the implementer to build something that already exists (or no longer applies). Verify first, then ask. **This phase is mandatory**, even when there are no open questions.

**Scoped paths** below means: the paths named in `## Scope`, plus every file cited in `## Context` and the open questions.

1. **Record the verification point**: `git rev-parse HEAD`. Phase 6 stamps this SHA into the frontmatter. If `git status --porcelain -- <scoped paths>` reports uncommitted changes, the tree you are about to verify is not the commit you are about to stamp — say so, and either get that state committed first or carry the caveat into the Phase 9 report. (The task file's own pre-run state is Phase 1's snapshot, not this check.)
2. **Classify each scoped path before trusting anything git says about it** (`git ls-files --error-unmatch -- "<path>"`). Tracked here → the history probes below mean something. On disk but untracked here — gitignored, or another repository's file; hq tasks naming `devtools/` paths hit this every time → git in this repo says nothing about it: verify it by reading, and run any history probe in the repo that owns it. Absent entirely → that is a finding (the construct is gone, or the brief's path was always wrong), never a silent skip. This step exists because `git log` over a wrong path prints the same nothing as "no drift".
3. **Read every file the task cites** (in Context, Scope, and the open questions). For `file:line` references, confirm the cited construct is still there; where it moved, re-anchor by symbol + quote (see the drift rules below).
4. **Diff the task's vintage against HEAD**, over the scoped paths step 2 confirmed tracked here: the vintage is the frontmatter `finalized-at:` SHA when present (the claims were last verified there — Phase 6 stamped it), else the commit that created the task file (`git log --diff-filter=A --format=%H --follow -- <task-file> | tail -1`). Then `git log --oneline <vintage>..HEAD -- <scoped paths>`, and `git diff <vintage> HEAD -- <scoped paths>` where the log alone doesn't settle whether a cited construct survived. Never window by date (`--since`): commit dates aren't topology — a branch merged after the task was created carries commits dated before it, and the date window silently excludes exactly those. A task file with no creating commit was never committed — it has no vintage; skip the window and rely on steps 3 and 5's direct verification. Skim any commit that plausibly touches the task's claims.
5. **Spot-check the strongest factual claims** with grep — "X is never assigned", "nothing checks Y", "the only place that does Z". Absolute claims are exactly the ones that rot silently, and they are usually one `grep -rn` away from confirmation or refutation.
6. **Verify the contract, not just the narrative.** Walk the acceptance criteria against HEAD and note each as met, partially met, or no evidence — landed work that already satisfies a criterion is exactly the "build something that already exists" failure this phase exists to catch. A contract change (ticking, dropping, rewording a criterion) is proposed to the user in Phase 5, never applied silently. Then check `dependencies:`: the completion convention deletes finished briefs, so a slug matching no task file is ambiguous — disambiguate with `git log --diff-filter=D --oneline -- "<tasks>/**/<slug>.md"` (deleted-as-completed → propose removing it from the list; no deletion either → a typo to fix). A dependency still open means Phase 7 would be designing against code that does not exist yet; the brief must say so.
7. **Scale depth to `effort:`**: for `small`, reading the cited files suffices; for `medium`/`large`, also fan out an `Explore` subagent over the scoped subsystem so the verification isn't limited to the paths the (possibly stale) task happens to name.

Then act on what you found:

- **If verification shows the task is already done or no longer applies, stop finalizing** — Phases 4–9 assume a task worth handing on. Already done (the work is in the tree, the criteria are met, only the brief never closed) → say so and offer the `task-implement` skill, whose close-out path owns that state. Moot (the premise is gone, superseded, overtaken by other work) → present the evidence and recommend deletion or reprioritization — the proposal is the whole deliverable here: this skill deletes and moves nothing, and acting on the recommendation (removing the file, or re-bucketing via the `task-move` skill) is the user's, outside this run. Do not resolve open questions about work that should not happen. Either disposition message is also the user's first contact with this task in a long while — write it to Phase 4b's zero-context rules: plain terms, every repo-specific name glossed or dropped.
- **Rewrite `## Context` / `## Scope` so they are true at HEAD.** Say what changed and name the commits that changed it — the implementer should inherit the corrected history, not rediscover it. Prefer **durable anchors** — a symbol name plus a short greppable quote (`` `run_tools`'s `if isinstance(result, Exception)` branch ``) — over bare line numbers, which rot fastest; keep line numbers only as a secondary convenience.
- **If verification answers or moots an open question, don't silently drop the question.** Carry the evidence into the Phase 4a prep and let the user confirm the evidence-based resolution in Phase 5 — the answer changed because the ground changed, and the user should see that.
- **Re-check `effort:` and `priority:`** against the corrected picture. If verification resized the task (machinery already landed; the problem grew), propose the change alongside the Phase 5 questions.
- Any rewrite in this phase makes the run **authored-content** (Phase 9) — the user will review it before commit.

---

## Phase 4 — Prepare the interview, then orient the user

An empty agenda skips this phase and Phase 5 — but the agenda is not known
until 4a's solution review has run. Zero open questions and no Phase 2–3
proposals (structural gaps, contract, effort, priority, dependencies) only
says the *author* asked nothing; for a `medium`/`large` task, 4a's sketch and
review still run, and can put items on that empty agenda. Skip exactly when
nothing comes out of them either — and immediately for a `small` task, which
gets no review.

Invoking this skill is usually the user's first look at the task in weeks. The
interview asks them to decide things, and a decision made without footing is a
coin flip recorded as a decision — so before any question is asked, this phase
builds the footing. Until 4b, nothing here is shown to the user, and the task
file is edited in exactly one case: a brief defect adopted from the review's
evidence (4a), which makes the run **authored-content** (Phase 9).

### 4a — Sketch the solution, red-team it, then prepare the interview (internal)

First, sketch the intended approach end-to-end, internally: which constructs
change, in what order, what each change does — working notes, not the Phase 7
section. The sketch exists because forks surface when the road is walked, not
when it is described. Phase 7's loopback already catches them, but only after
the interview is over; walking the road now moves that discovery to where the
user is still in the room.

For a `medium`/`large` task, dispatch two read-only subagents (`Explore`)
against the sketch — `small` tasks skip them, as with Phase 3 step 7's
fan-out. Both prompts carry the same two clauses: **every finding must cite
file and line**, and **"no findings" is a success state, not a failure to
perform** — the subagent is checking an approach, not justifying its
dispatch.

- **Refutation** — gets the sketch and the task file. Its one job: find a
  concrete reason this approach fails against HEAD.
- **Blast radius** — gets the change surface (the files and symbols the
  sketch touches). Its one job: walk one hop outward — callers, consumers,
  integration points — and report what the change would affect that the
  brief never mentions.

Adjudicate the returns yourself; raw subagent output never reaches the user.
A finding without code evidence dies. Sort each survivor by what it is:

- **A genuine fork** — two reasonable implementers would deliver materially
  different things, and neither code nor repo convention settles which —
  joins the agenda as a question.
- **A design wrinkle** — real, but any competent design just handles it — is
  held for the `## Recommended solution`, which already owes the implementer
  its wrinkles (Phase 7).
- **A defect in the brief** — a wrong path, a stale claim Phase 3 missed —
  is fixed in the document now; the fix makes the run **authored-content**
  (Phase 9).
- Everything else is discarded, unrecorded.

The fork bar is deliberately high: every question the review adds spends the
scarcest resource this skill manages, the user's attention. When in doubt,
downgrade to wrinkle — the user reviews Phase 7's section in the staged diff
at their own pace, where a question would have cost a decision on the spot.

Then work every agenda item — the open questions, Phases 2–3's proposals,
and the review's surviving questions — to a presentable state *before*
anything is shown to the user:

- Assemble the evidence the item turns on from Phase 3's findings; where the
  analysis needs a read or grep Phase 3 didn't make, make it now, not
  mid-interview.
- Enumerate the candidate answers with genuine trade-offs and form a
  recommendation with its reasoning — the material 5a's question messages are
  built from.
- Note the facts the item's discussion will rely on.

Then split those noted facts: **a premise shared by two or more items, or one
the task itself stands on, goes into the orientation card; a fact only one
item needs stays out**, delivered just-in-time in that item's own turn. This
rule — not a summary of the document — is what scopes the card: the user gets
exactly the footing the upcoming decisions need, nothing else.

Order the agenda by leverage: Phases 2–3's proposals first — they change the
premises the questions stand on — then the question whose answer constrains
the most others. Prep for later items is provisional: earlier answers reshape
them, and 5a revises before presenting rather than presenting as planned.

Nothing from this step is shown yet, and the card must not front-run the
interview: recommendations, trade-offs, and advocacy stay in Phase 5. Tailored
means the *context* is chosen for the decisions ahead — not that the decisions
arrive pre-argued.

### 4b — Orient the user

Present one orientation card, then stop and let the user set the pace. Assume
a reader with **zero context** beyond "I filed this once"; shrink the card
only on evidence from this conversation (a `task-next` or `task-status` report
on this task already on screen), never on how recent the file looks.

The card is one screen, hard caps, in this order:

- **The problem** — ≤3 sentences, plain words: what's wrong or missing, and
  why anyone cares. Seed from `**In brief**:` where present, corrected to what
  Phase 3 verified — never pasted stale.
- **The proposed fix** — ≤3 sentences, same register.
- **What's changed since this was written** — only when Phase 3 found drift;
  1–2 sentences naming the practical effect, not the commits.
- **What you'll be deciding** — the agenda in 4a's order, one plain line each
  with its stakes ("decides scope", "wording only, low stakes"). Phase 5
  numbers its turns against this list.
- **Terms that will come up** — ≤3 entries, only where a repo-specific term is
  unavoidable in the questions ahead.

Writing rules for the card — they also bind Phase 5's question messages and
Phase 3's early-exit dispositions:

- Every repo-specific noun is glossed in plain words on first use or omitted:
  "the script that copies the shared skills into each repo" beats its
  filename, which goes in parentheses only where a question will need it.
- Each line is understandable without the others — no explanation that leans
  on adjacent material.
- Depth on demand, not by default: the card is the floor. Close by naming one
  or two expansions on offer ("I can go deeper on why the current approach
  fails") rather than including them.

End the turn in prose with the three exits visible:

> Ask me anything about this, say **ready** for question 1 of N, or say
> **take your recommendations** to see the whole batch at once.

Loop on the user's questions until a clear affirmative — the 4a prep usually
already holds the answer; where it doesn't, go look rather than improvising.
**ready** (any clear affirmative) advances to Phase 5. **take your
recommendations** jumps to 5b's wholesale path: present every prepared
recommendation with a one-line reason, and on the user's confirmation give
each its own **Recording:** line.

---

## Phase 5 — Resolve open questions by discussion

Skipped exactly when Phase 4 was skipped. Proposals without open questions
still use 5a's shape — one per turn, evidence first, a **Recording:** line on
convergence.

Open questions are settled **in conversation, one question per turn** — never
through a question popup.

### 5a — Discuss, one question per turn

Follow the order Phase 4a prepared and the orientation presented — the user
saw that list and may have reordered or pre-answered against it; honor that.
The orientation already did the roadmap's job, so open directly with the first
question, numbering every turn against the orientation's decision list
("question 2 of 5").

Each question message assumes **the orientation card and nothing else** — not
the task document, not earlier threads beyond their **Recording:** lines. The
question-specific facts 4a held back arrive here, in the turn that needs them.

For each open question, post one message containing:

1. **The question**, quoted from the task (trimmed, not paraphrased), and why it
   exists — what the decision impacts (cost, risk, scope, blast radius), in
   plain English, with paths where they help.
2. **Epistemic status**: what you **verified against code in Phase 3** versus
   what you are **assuming from the document**. If verification changed the
   question's premises or effectively answered it, lead with that evidence —
   "verified" versus "assumed" is the whole ballgame.
3. **The candidate answers**, each with genuine trade-off analysis — enough that
   the user could argue for any of them, not one-line labels.
4. **Your recommendation and its reasoning.**

Then **stop: end the turn in prose, no tool call after the context block**, so
the full picture is the last thing on screen and the user replies in the
conversation. Keep the block self-contained and skimmable.

Iterate until the question converges: answer follow-ups, sharpen or add
options, absorb corrections. Answers to earlier questions often reshape later
ones — that is the point of going one at a time; revise the later questions
before presenting them rather than presenting them as originally planned. An
answer that misreads a premise is an orientation gap, not a user error:
re-ground that one premise in plain terms, then re-ask.

Two ways out mid-phase, both legitimate. An answer that undermines the task's
premise — the work is moot, already done, or belongs elsewhere — ends the
interview: return to the Phase 3 disposition (close-out, deletion,
reprioritization) instead of resolving questions about work that should not
happen. And the user stopping early is a valid outcome, not a failed run:
record what converged, leave the rest open, and let readiness fail on them
(Phase 8) — the brief is partially decided and should say so.

### 5b — Record each resolution

When a question converges, restate the outcome in a single line before opening
the next question:

> **Recording:** <the decision, in one or two sentences>

That line is the decision record — Phase 6 copies its text into `## Decisions`
verbatim, which is what lets a run stay **self-contained** (Phase 9):
everything in the Decisions diff was shown to the user in the conversation.
Decisions is read by a later session that does not have this conversation, so
the line states the decision itself — never a pointer like "as recommended" or
"per the above". If the user corrects a Recording line, re-issue it corrected,
and when a later answer contradicts an earlier Recording, surface the conflict
and re-issue that line too; the last version stands.

Special cases:

- The user answers in multi-paragraph prose worth preserving whole → mark it
  multi-paragraph for Phase 6 formatting and carry their words, not a summary.
- The user accepts your recommendations wholesale ("take your recommendations
  for the rest" — mid-interview, or from the orientation before any question
  was asked) → fine, but each remaining question still gets its own
  **Recording:** line stating the decision — one message may carry them all —
  so the Decisions diff stays complete.
- The user explicitly defers a question → **keep** it in the Open questions
  section and write no Decisions entry: the question staying open is the
  record, and a Decisions bullet would only duplicate when a later run
  resolves it. The task will fail readiness on it (Phase 8) — that's
  intentional. A deferred question the *review* raised (4a) was never in the
  section — Phase 6 adds it there, worded exactly as the conversation asked
  it, so the same rule can hold; text shown verbatim in the discussion keeps
  the run self-contained (Phase 9).
- A decision spins off work that doesn't belong in this brief → create the
  follow-up as its own task file from the `task-create` skill's template,
  naming the new file in the question's **Recording:** line; the new file
  makes the run **authored-content** (Phase 9).

---

## Phase 6 — Record the resolutions

Every edit in this phase is pre-approved by construction: its content was either confirmed verbatim in the Phase 5 discussion — a **Recording:** line — or is machine-derived from Phase 3. This phase on its own never makes a run authored-content.

Edit the task file:

1. Insert (or extend) a `## Decisions` section. Placement: immediately after `## Stopping conditions`; if that section is absent, immediately before `## Out of scope`; if both are absent, at end of file. If the section already exists, append new entries to it.

2. Format each resolution as a single bullet:
   ```
   - **Q: <original question text>** — <the final **Recording:** line's text, verbatim>
   ```
   For multi-paragraph answers, use a sub-heading instead:
   ```
   ### <short version of the question>
   
   <user's multi-paragraph answer>
   ```

3. Remove from `## Open questions` **only what this run accounted for** — the questions resolved in Phase 5. Deferred questions stay, and so does anything else still sitting in the section; a deferred question the solution review raised (Phase 4a) is *added* here, worded exactly as the conversation asked it — deferral keeps a question in the brief, and a review question was never in the file to keep. Delete the heading itself only when those removals leave it empty — nothing left but whitespace and HTML comments, which readiness rule 6 (Phase 8) already treats as resolved — and take any leftover comments with it.

   Never clear the section wholesale. Leftover text means Phase 2's extraction missed a question, which was therefore never asked — leaving it in place fails rule 6 in Phase 8, and that failure is how it surfaces. Deleting the section would erase the question and pass.

4. Apply the contract and frontmatter changes the user confirmed through a **Recording:** line — a ticked, dropped, or reworded acceptance criterion, or any frontmatter field the discussion corrected (`status:`, `effort:`, `priority:`, `dependencies:`) — Phases 2–3's proposals, settled in Phase 5. A change with no Recording line behind it does not belong in this phase.

5. Stamp the verification point: set `finalized-at: <sha>` in the YAML frontmatter — the HEAD SHA recorded at the start of Phase 3, overwriting any previous value. This records "the claims in this document were verified true as of this commit": it becomes the vintage Phase 3 diffs from on the next run (`<sha>..HEAD` over the scoped paths), and whoever picks the task up re-verifies the brief the same way when that range is non-empty. Briefs rot while they sit; the stamp is what makes that rot detectable mechanically.

---

## Phase 7 — Write the recommended solution

If the Phase 3 verification plus the resolved questions determine a concrete approach, write (or update) a `## Recommended solution` section. Placement: immediately after `## Context`, before `## Scope` (problem → design → footprint); when `## Context` is absent, immediately after `## Goal`.

Rules for the section:

- **Advisory, not contract.** The acceptance criteria remain what the implementer is graded on. The implementer follows this design unless the code at HEAD contradicts it, and notes any deviation — the shared execution-discipline rules state this; don't restate it in every task.
- **Ground every design point in what you verified.** Name the functions and files (durable anchors, per Phase 3), state why each piece goes where it goes, and flag any wrinkle the implementer would otherwise trip on. The bar: a fresh session should be able to implement without re-deriving the analysis.
- **Skip it when it would be padding.** A task whose approach is obvious from Goal + acceptance criteria (mechanical rename, config flip, doc fix) doesn't need one — an empty design section is worse than none.

Drafting is where unmade decisions surface. If writing the section exposes a fork the interview never settled, don't choose silently: return to Phase 5 with that one question, then resume here with the answer recorded.

For a `medium`/`large` task, one more subagent runs after this phase — even when the section itself was skipped as padding, because its subject is the whole brief: a **cold read**. Hand an `Explore` subagent the task file path and *nothing else* — not the sketch, not this conversation — because this session can no longer judge whether the brief stands alone: having run the interview, it fills every gap in the text from conversation memory without noticing. The subagent reads the brief with the repo at hand — exactly the implementer's situation at pickup — and reports each place it would have to guess between materially different deliverables, under 4a's two clauses (file-and-line evidence; empty findings are success). Adjudicate by 4a's rules: a genuine fork returns to Phase 5 as one question; a gap the design can settle sharpens this section; the rest is discarded. Phase 9 reports the outcome either way.

Writing or updating this section makes the run **authored-content** (Phase 9): the commit offer will direct the user to review it in the staged diff before accepting.

---

## Phase 8 — Validate readiness

Run the same bundled checker from Phase 2 after the brief is complete, and read all of its output plus its exit code. Its eight numbered records are the readiness verdict; do not reproduce or re-judge them in this skill. Exit 0 means every blocking rule passed, exit 1 means the printed `FAIL` records name what remains, and exit 2 is a usage or repository-context error to fix before reporting readiness.

One check warrants an interaction of its own: **no `**In brief**:` paragraph, or it still holds the template comment** — warn, do not fail. In brief serves human triage, not implementation correctness, so a missing one never blocks readiness; tasks predating the field are expected to lack it. Offer to write one (a yes/no capture — use the popup); if the user accepts, authoring it makes this an **authored-content** run (Phase 9).

### Move the passing brief

Only when the checker exits 0, move the task into `<tasks>/finalized/`. A task
already there stays in place. If the directory does not exist in an older task
tree, create it with a short `README.md` saying that briefs there passed
`task-finalize`, are ready for supervised implementation, and are defined by
`.agents/skills/task-create/bucket-definitions.md`; this keeps the directory
tracked after it empties. The README is machine-derived scaffolding, not authored
content. Support both tracked and untracked source files without losing staged content:

```bash
mkdir -p <tasks>/finalized
git add <source-task-file>
git mv <source-task-file> <tasks>/finalized/<task-name>.md
```

Update `task_file` to the destination and retain the source path for Phase 9's
staging, diff attribution, and path-scoped commit. The rename is machine-derived
from the successful readiness verdict and therefore does not make the run
authored-content. If readiness exits 1 or 2, do not move the brief.

---

## Phase 9 — Summary and commit

First, look at what is already staged: `git diff --staged --name-only`. Anything there this run never touched is the user's parked work — leave it staged, exclude it from the attribution below, and name it in the commit offer (the commit's pathspec keeps it out). Then stage everything this run touched, including both sides of the task move and any files the run created. Then classify the run as **self-contained** or **authored-content** from the staged diff (`git diff --staged`), not from memory — attribute every hunk in the run's own files:

- Hunks the Phase 1 snapshot already showed are the user's own pre-run edits: they don't reclassify the run, and the commit offer discloses them.
- A hunk that traces to a Phase 6 step — a `## Decisions` bullet carrying a **Recording:** line's text, a per-question `## Open questions` removal, a confirmed contract or frontmatter adjustment, the `finalized-at:` stamp — keeps the run **self-contained**. Multi-paragraph answers the user typed are still self-contained: they're the user's own words, shown in the conversation.
- The Phase 8 rename into `finalized/` is machine-derived and keeps the run self-contained.
- Any new file, and any hunk you cannot attribute — a drift-corrected `## Context` or `## Scope` (Phase 3), a brief defect fixed on the solution review's evidence (Phase 4a), a `## Recommended solution` (Phase 7), an `**In brief**:` paragraph (Phase 8's offer), spun-off follow-up task files — makes the run **authored-content**. A Decisions bullet that paraphrases instead of quoting its Recording line counts too: the guarantee is *shown verbatim*, and the diff is where that claim gets checked.
- A task file that started untracked is classified by its own rule, not hunk attribution: the staged diff shows one new file mixing the user's pre-run content with this run's edits, and Phase 1 recorded no pre-image to attribute against. That run is **authored-content** — the review surface is the whole document, which is exactly what the commit adds.

Then print a final block with:

- The task's destination path in `finalized/` (and its source bucket when a move occurred).
- The Phase 3 verification result: what had drifted and was corrected (with the commits responsible), or "no drift found". Name the `finalized-at` SHA, and carry any Phase 3 caveat (the tree held uncommitted scoped changes at verification time).
- Number of open questions resolved.
- Whether any were deferred (and which).
- Whether a `## Recommended solution` was written or updated.
- The solution review's outcome, per pass (4a's refutation and blast radius, Phase 7's cold read): skipped for `small` effort, or what each raised and where it landed — interview question, design wrinkle, brief fix, or discarded. A pass that raised nothing is reported as "ran clean": that is a result, not an omission.
- Readiness: the bundled checker's `PASS` / `FAIL` / `WARN` records and exit code, plus the In-brief outcome (Phase 8).
- The run classification (self-contained vs authored-content).

Pick the commit message from the first row that applies:

| Run | Message |
|-----|---------|
| Task file started untracked | `docs(tasks): add <task-name> (finalized)` — and say in the offer that the commit adds the whole document, not just this run's edits |
| Authored content | `docs(tasks): finalize <task-name>` |
| Resolved questions, nothing authored | `docs(tasks): resolve open questions on <task-name>` |
| Stamp-only (no questions, nothing authored — a pure re-verification) | `docs(tasks): re-verify <task-name> at HEAD` |

Then make the commit offer. Its shape depends on the classification:

**Self-contained run** — every staged change in the run's own files was either confirmed through the Phase 5 discussion or is the user's own pre-run edit. When the Phase 1 snapshot was dirty, put a short summary of the pre-run diff in the offer (diffstat plus a one-line gist), so the Yes is informed rather than assumed. Ask (a yes/no capture — exactly what the popup is for):

- **question**: "Commit the staged changes now with message `<chosen message>`?"
- **header**: "Commit"
- options:
  - `Yes — commit now` (Recommended)
  - `No — leave staged for review`

**Authored-content run** — the staged diff includes content the user never saw, and it is **not pasted into the conversation**: the IDE's diff view is the better reading surface. Name what was authored (files and sections), point at the staged diff, and ask:

- **question**: "This run authored <named files/sections> beyond the confirmed discussion — review the staged diff in your IDE, then commit with message `<chosen message>`?"
- **header**: "Commit"
- options:
  - `Yes — reviewed, commit now`
  - `No — leave staged for review`

  Neither option is marked recommended here: the right answer depends on a review this conversation cannot see.

If the user picks Yes, run `git commit -m "<chosen message>" -- <source-task-file> <finalized-task-file> <files this run created>` (omit the source when no move occurred) — the pathspec scopes the commit to the run's files, so the user's parked staged work stays staged and uncommitted — and report the resulting commit hash. If No, print:

> Left staged. Review the staged changes (`git status`, `git diff --staged`, or your IDE) and commit when satisfied.

Either way the run ends there: this skill never pushes, and never offers to — synchronizing git with the remote is the user's call, made outside this skill.
