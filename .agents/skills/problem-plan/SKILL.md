---
name: problem-plan
description: Decide what to do about one problem record in docs/work/problems/ — gate it on current status and prior plans, diverge over candidate resolutions with a small read-only fan-out when the fix is not already settled, agree the approach with the user one fork per turn, then hand the decision into one or more tasks (or a cross-repo handoff, a design document, or an accept/defer line on the record) and offer task-finalize. The decide stage between problem-status and kaizen-resolve; the record never gains a solution section. Requires a record name or path.
---

# Plan a problem

Take one record from `docs/work/problems/` and run it to a decision: confirm
the flaw still stands, work out the candidate ways of dealing with it, settle
the approach with the user, and hand that decision to whatever owns the next
artifact. This is the decide stage of the problem lifecycle. `problem-create`
and `kaizen-review` file a record; `problem-status` and `problem-audit` say
whether it still holds; **this skill decides what to do about it**;
`task-finalize` designs the chosen fix; `kaizen-resolve` retires the record
once the flaw is verified gone.

The record itself is not finished by this skill and is never deleted by it. A
problem persists until its flaw is verified gone, whatever was decided here.
What changes is the task tree, and at most one line of the record. A record
never gains a solution section: the chosen fix lives in the task that cites it.

**Run this on the strongest model available.** The decision made here is
inherited by the task, by `task-finalize`, and by every session that picks the
task up. If you are on a weaker model, say so and offer to switch before
Phase 4.

**Arguments**: a problem filename (with or without `.md`), a path, or an H1
title — **required**. This skill plans the record it is pointed at and never
picks one; `problem-status` with no argument is the sweep that picks.

## Repo conventions (resolve first)

- **Problems root**: `docs/work/problems/`, with records directly under it
  (legacy, unbucketed) or in its `now/`, `soon/`, `later/`, and `never/`
  buckets. Its `README.md` is the local rule source: read it before Phase 2.
  The `**Disposition**:` line this skill writes is defined in the shared
  problem template and the problems README seed; a repository that also links
  GitHub issues defines an `**Issues**:` line in its local READMEs, and the
  Issues steps below apply only where it does.
- **Tasks root**: `docs/work/tasks/`. Its `README.md` carries the repo-specific
  authoring notes (jargon to keep out of `**In brief**:`, any Issues line);
  read it before writing task prose.
- **Shared files**, resolved from this skill's **physical** directory — follow
  every symlink first, per
  [`skill-path-resolution.md`](../../../docs/skill-path-resolution.md) — read
  only when their step comes up, and named in the report when read:

  | Path from the physical directory | When |
  |---|---|
  | `../problem-create/bucket-definitions.md` and `list-records.py` beside it | Phase 1: finding the record |
  | `../problem-status/SKILL.md` | Phase 2: the status gate |
  | `../task-create/SKILL.md` | Phase 7: writing a task |
  | `../../../docs/cross-repo-handoffs.md` | Phase 7: a handoff |
  | `../../../docs/templates/idea-doc.md` | Phase 7: an idea, where the local ideas README is silent |

- **Local planning conventions**, when the repository keeps them:
  `docs/planning/designs/README.md` for a design document,
  `docs/planning/ideas/README.md` for an idea document.

---

## Phase 1 — Resolve the record

Run `python3 <physical-problem-create-dir>/list-records.py <repo-root>` and
check its exit status: a failed inventory is a layout error to report, not an
empty collection. Resolve the argument to exactly one record in that
inventory, in any bucket. Accept an exact path, a filename, or an H1 title.
More than one match: list them and ask which. No match: say so and stop. Print
the resolved path and its bucket before continuing. A record in `never/` is
parked by the user's explicit direction: say so, and plan it only if the user
wants it re-opened.

Read the record end to end. Note its `**In brief**:` paragraph (or, in a legacy
record without one, the scope statement as a disclosed fallback), every cited
path or construct, any `**Issues**:` or `**Disposition**:` line, and anything
under **See also** that names a fix direction.

Snapshot the record's pre-run state — `git status --porcelain -- <record>`,
plus `git diff HEAD -- <record>` when it reports modifications. Phase 7 may
edit the record, and this snapshot is the only way Phase 8 can tell the user's
own pre-run edits from this run's.

When the record's **See also** names a sibling record as a neighbouring flaw
in the same construct, the pair is the run's subject: gate the sibling with
the same searches and the same read, give every lens both paths, ask its
disposition as its own question after the primary's, and let the interview
decide whether one task cites both or each gets its own. The commit message
names the primary's slug; its body names the sibling.

---

## Phase 2 — Gates

Run these in order. The first that fires decides the run, except the repair,
which fixes the record and continues.

1. **Already decided.** The record carries a `**Disposition**:` line. Report
   it, quoted, and stop — unless the user asks to revisit, in which case
   continue and let Phase 7 replace the line.

2. **Already planned.** Search for the record's filename (without `.md`)
   across `docs/work/tasks/now`, `soon`, `later`, `finalized`, `parked`,
   `queued` where it exists, and `docs/work/handoffs/`, by explicit path —
   never a recursive grep from the root whose omissions are invisible. A hit
   from a live task: report "already planned: see `<task>`", offer
   `task-finalize` or `task-implement` on it as its state warrants, and stop.
   A hit from `parked/` only is parked work: stop, show its parking note, and
   continue only if the user wants to re-open it. Citations from planning documents, journal
   entries, and other records are context, not plans.

3. **Status.** Apply `problem-status`'s single-record procedure and verdict
   vocabulary in this session: read its skill text and follow it, rather than
   invoking it as a separate skill whose standalone report would displace the
   card. Its verdict and the evidence behind it go on the card and into the
   task's Context. For a flaw in model behaviour, the verdict is about the
   mechanism that produces it — the prompt, the inputs it is given, the
   absence of a check — not the rate at which the symptom has lately
   appeared: an intact mechanism is Still present however rare the symptom,
   a changed mechanism is what makes Likely fixed, and the measured rate
   goes in the task's Context. Act on the verdict:
   - **Still present** — continue.
   - **Likely fixed** — hand to `kaizen-resolve` and stop. Do not plan a fix
     for a flaw that may be gone.
   - **Premise drifted** or **Evidence rotted** — repair before planning:
     rewrite the affected sections so they are true at HEAD, keeping the
     record's structure, and name the commits that changed the ground. This
     is authored content (Phase 8). If the repair shows no flaw remains, that
     is Likely fixed: route to `kaizen-resolve`. Stale line numbers alone are
     not drift — the task will carry durable anchors — so leave them.
   - **Cannot tell** — say exactly what could not be checked and ask whether
     to plan on the record's claims or gather evidence first. Planning on
     unverified claims is allowed; the task's Context must say so.

4. **Issues** (not a gate; only where the repository defines an Issues line).
   When the record has no `**Issues**:` line and the `gh` CLI is available,
   search open issues once for the record's subject. A hit becomes the
   task's Issues line in Phase 7. No hit, or no `gh`, is reported and not
   pursued. A present Issues line is read, not trusted:
   the linked issues' bodies are part of Phase 3's read or lens 4, and a
   record claim they contradict is a record defect.

---

## Phase 3 — Size it, and check for a named fix

Records carry no effort field, so size the *change*, not the record. The
problem is **small** when the flaw lives in one construct on one surface and
the candidates the record names each touch a handful of files. Anything else
is not small. A wider candidate that your own read adds does not change the
sizing: it joins the card as a candidate and the interview settles it. Small
skips Phase 4. The sizing and its basis go in the Report, not on the card;
the card's status line says only whether the fan-out ran. A user who wants
the fan-out on a small problem asks for it from the card; a not-small sizing
dispatches without asking.

When Phase 4 is skipped, the candidates come from the record and from your
own read of the constructs it cites — make that read now, including a look
for prior art and for the cost of leaving the flaw alone, so the card is not
thinner for having skipped the fan-out. The read follows the cause past the
record's citations to the construct that produces the flaw; that can be
several hops and many tool calls, and it is the work of lens 1 done inline,
not a glance.

A fix named under **See also**, or by the user at invocation, becomes the
default recommendation — but it is a candidate until the user confirms it. A
filing-time hint was written before anyone analysed the fix, and records that
name a direction often say in the next sentence that the choice is open. Skip
Phase 4 only on the user's confirmation; `task-finalize` will still red-team
the confirmed approach later.

---

## Phase 4 — Diverge

Skipped when the problem is small or the user confirmed a named fix. The
purpose is to widen the candidate set before anyone argues for one approach:
this skill diverges, `task-finalize` converges with its refutation,
blast-radius, and cold-read passes. Do not refute here.

Dispatch read-only subagents (`Explore`), in parallel where the harness
supports it. Lenses 1 and 2 always run; 3 and 4 run when the record's subject
gives them something to look at — a class of fix with likely precedent, a
dependency or sibling-repository surface. Two to four agents, never more; do
not borrow `audit-and-fix`'s lens count. Without subagent capability, run the
lenses sequentially in the current session and keep their findings separate
until adjudication.

Each prompt is self-contained: the record's path, the lens text, and two
clauses — **every finding must cite file and line**, and **"no findings" is a
success state, not a failure to perform**. Nothing from this conversation,
and no candidate preloaded into any lens. A lens reads, searches, and
computes over what it finds, including local data the repository documents;
it writes nothing in the repository and never exports private or
confidential content to a file. Cap each report at about 800 words: a longer
one arrives truncated and costs a round trip to recover.

1. **Root cause at HEAD.** Why the flaw exists; the construct that is the
   cause rather than the symptom; which of the record's claims still hold.
2. **Candidate resolutions.** The distinct approaches, each with what it
   touches, one hop of blast radius, what it would *not* fix, and rough cost.
   Reject nothing — adjudication is where candidates die.
3. **Prior art.** The pattern this codebase already uses for this class of
   fix: a working counter-example, a helper, a style-guide convention; the
   same in mounted dependencies when relevant. The precedent and the
   convention, not an inventory of every related mechanism.
4. **Do nothing, or upstream.** The cost of living with the flaw as it is;
   whether the fix belongs to a dependency or another repository; whether an
   existing task or design already covers it.

Adjudicate as `task-finalize`'s solution review does: raw subagent output
never reaches the user; a finding without file-and-line evidence dies. Then
sort each survivor:

- **A candidate** — an approach two reasonable implementers would deliver
  differently — joins the card and the interview.
- **A wrinkle** — real, but any competent design of the chosen approach
  handles it — is held for the task's `## Recommended solution`.
- **A record defect** — a wrong path, a stale claim Phase 2 missed — is held
  and repaired in Phase 7 alongside the other artifacts, so that a run the
  user stops early writes nothing; authored content (Phase 8).
- **An incidental defect** — real, evidenced, and outside this record's
  subject — is held for the Report's found-along-the-way item and the capture
  offer after the run. It never reaches the card.
- Everything else is discarded, unrecorded.

---

## Phase 5 — Orient

Present one card, then stop and let the user set the pace. The card has one
job: move the user's attention onto the problem and the live ways out, so
that a reader with zero context beyond "I filed this once" finishes it knowing
what is wrong and what the choices are, ready for question 1. Everything that
serves the agent or the record rather than that reader — gate detail, the
sizing, the rejected candidates, the forks ahead, implementation choices,
record repairs, incidental findings — stays off the card; the Report carries
it. Every repo-specific noun is glossed in plain words in the sentence that
first needs it, or omitted; there is no glossary. The card is the floor, with
depth on offer rather than included.

- **A status line**, first and alone, in italics, so the eye can skip it: the
  status verdict; that nothing plans the record, or what does; whether the
  fan-out ran. Fragments separated by middle dots, no prose.
- **The problem** — ≤3 sentences, plain words, from `**In brief**:` corrected
  to what Phases 2 and 4 verified. Never pasted stale. The first sentence
  names the surface the user sees — which step, screen, or output — before
  any mechanism, so the reader can place the flaw without asking where it
  happens.
- **The candidates** — the live ones only, each as a letter, a bold name of a
  few words, and one plain sentence saying what it does. No trade-offs, no
  file or mechanism names, no advocacy: the interview carries those. Include
  "leave it" whenever Phase 4 or the read makes that credible. Rejected
  candidates are not listed; they are held for the interview, where they
  answer a user who proposes one, and for the task's Decisions.

End the turn in prose with the three exits visible, N being the number of
questions the interview will ask:

> Ask me anything about this, say **ready** for question 1 of N, or say
> **take your recommendations** to see the whole batch at once.

---

## Phase 6 — Interview

One question per turn, in conversation, never through a question popup.
Question 1 is always the disposition: which exit, and for a fix, which
approach. The questions after it are only the forks whose answer changes
which task is filed, how many, its goal, or its bucket. For a small problem,
fold the bucket into question 1's recommendation rather than spending a turn
on it; ask it on its own only when the focus document or an earlier answer
makes it contested. Implementation forks belong to `task-finalize`, not
here: hold them for the task's `## Recommended solution`, named as its
decision to make.

Each question message carries, in this order:

1. the question and why it exists — what the decision changes;
2. the candidate answers, each as a letter, a bold name of a few words, then
   what it does and its trade-off in plain words, enough that the user could
   argue for any of them. Every question's candidates are lettered, so the
   user can answer with one letter. A candidate's text assumes only the
   problem statement and the answers so far: a precedent, mechanism, or
   subsystem it names is explained in the sentence that names it, never by
   reference to something the user has not been told;
3. your recommendation and its reasoning, in the same plain words; where it
   leans on a precedent, say what that precedent actually checks, so an
   analogy looser than it sounds is visible;
4. last, one line headed **Basis**, naming only what in this question rests
   on inference or on the record rather than on code verified in Phase 2 or
   4; when everything was verified, that one line says so. The verified
   evidence itself belongs in the task's `## Context`, not in the question.

Then stop, in prose, with no tool call after the block. A user who proposes
a candidate Phase 4 rejected gets the reason it was rejected, as push-back,
not refusal; the user's decision stands. A user who challenges the
recommendation itself gets a straight answer, agree or disagree and why,
and a revised recommendation when the challenge stands; such a challenge
usually lands on what the Basis line marked as inference, which is what
that line is for. Iterate until the question converges, and restate the outcome in one line before the next question:

> **Recording:** <the decision, in one or two sentences>

That line is the decision record: Phase 7 copies its text verbatim into the
task's `## Decisions`, so a later session without this conversation reads the
decision itself, never "as recommended". A rejected candidate gets its reason
in the same line. **take your recommendations** presents every prepared
recommendation with a one-line reason and, on confirmation, gives each its own
Recording line.

Two exits mid-phase. An answer that moots the record — already fixed, premise
gone, belongs elsewhere — returns to Phase 2's routes. The user stopping early
writes nothing: the record stays exactly as it was, and the report says so.

A request mid-run for an artifact outside this record — a task for a sibling
record, a capture, a note — is done before the next question, by that
artifact's own skill procedure applied in this session, and it gets its own
commit in Phase 8, offered beside the plan's, never folded into it. Where it
changes the weight of a candidate, the next question says so.

---

## Phase 7 — Exits

| Decision | What is written |
|---|---|
| The fix is decided | One or more tasks, below |
| The fix belongs to another repository | A handoff, below |
| The fix needs a design before tasks can be cut | A design document, below |
| A rejected candidate is worth keeping in view | An idea document, below — alongside the exit that won |
| Live with it, for now or for good | A `**Disposition**:` line on the record, below |
| Already fixed | Nothing here — `kaizen-resolve`, from Phase 2 |

One record may take two exits — a handoff plus the local task that waits on
it, an accepted flaw whose worst symptom still gets a task, a task plus the
idea document for the richer candidate it beat. Say so when you see it.

Record defects held from Phase 4 are repaired now, whatever the exit: rewrite
the affected sentences so they are true at HEAD, keep the record's structure,
and add nothing about the decision. Authored content (Phase 8).

### Tasks

Follow the `task-create` skill's procedure in this session, through writing
the file: read its text and apply it, rather than handing control to it. Its
gather-info questions — name, bucket, goal, effort — are answered from the
interview, not re-asked. Stop at its Confirm phase; take neither its finalize
offer nor its ship step, both of which would strand the rest of this run. Then
edit the new brief so the decision travels with it:

- **`## Context`** — the flaw in two or three sentences, a relative link to
  the record, and what Phase 2 verified at HEAD (or that the plan rests on
  unverified claims).
- **`## Recommended solution`** — the chosen approach, grounded in what was
  verified, with durable anchors (a symbol plus a short greppable quote)
  ahead of line numbers. The wrinkles Phase 4 held go here.
- **`## Decisions`** — one bullet per Recording line, verbatim, including the
  rejected candidates and their reasons. Place it after `## Stopping
  conditions`; `task-finalize` appends to an existing section rather than
  duplicating it.
- **`## Open questions`** — only the forks the user chose to defer in the
  interview. An implementation fork left to `task-finalize` goes in
  `## Recommended solution`, named as its decision to make, not here.
  Everything settled leaves nothing here.
- **`**Issues**:`**, where the repository defines one — directly after
  `**In brief**:`: an issue Phase 2 found, and those on the record's own line
  whose subject the task fixes, not the record's whole line.

Several tasks when the record spawns several; each cites the record. No
index or table of problems needs an edit: a task citing the record is what
Phase 2's search, and `problem-status`, find.

### Handoff

Read the shared cross-repo handoffs guide and, when it exists,
`docs/work/handoffs/README.md`, then deliver the brief as the guide says for
this session: filed straight into a receiving repository you can see, with
`handoff-from:`, or written to `docs/work/handoffs/` with `handoff-to:` when
you cannot. A blind handoff counts as filed only once it is pushed; say that
in the report, because this skill never pushes. Where this repository owes
follow-up once the upstream change lands, file that as a local task in
`soon/` citing the handoff, so it is not forgotten.

### Design

Read `docs/planning/designs/README.md`, write the document in its format with
status `Proposed`, add its row to that README's table, and link the record from
it. A repository without a designs convention has no home for the document:
file a task instead whose deliverable is the design, citing the record, and
carry the interview's decisions in it as for any task. This exit is rare: most
product decisions are settled in the interview and travel as a task's
Decisions.

### Idea

For a candidate the interview rejected for now but wants to be able to pick up
later — usually the richer approach that lost to the cheap one. Read
`docs/planning/ideas/README.md` and follow its layout: topic subfolders, an
index row where a subfolder keeps one, a local template where it has one.
Where the local README is silent or absent, write from the shared idea
template. Lead with the problem, give the direction and the reason it was not
chosen now, leave the open questions open, and link the record and the task
under See also. A rejected candidate not worth keeping lives only in the
task's Decisions, with its reason.

### Accept or defer — the Disposition line

One line, with a fixed prefix so Phase 2 and a later sweep can find it:

```markdown
**Disposition**: Accepted YYYY-MM-DD. <One sentence: why living with it beats fixing it.>
**Disposition**: Deferred YYYY-MM-DD until <condition>. <One sentence.>
```

It goes directly after the `**In brief**:` paragraph, or after the record's
`**Issues**:` line when it carries one. Replace an existing line rather than
adding a second. The record stays in the collection because the flaw still
exists; the line records only the decision.

An **Accepted** record belongs in `never/`: the user's acceptance is the
explicit direction the problem bucket definitions require for parking, and the
Disposition line is the parking reason they ask to be recorded. Move it there
under those definitions' move rules — the record's own relative links and
every live inbound reference, repaired in the same change — or, where the user
wants it left in place, say so in the report. A **Deferred** record stays in
its bucket; `problem-reprioritize` owns any move among now, soon, and later.

---

## Phase 8 — Commit

Read `git status --short` first. Stage and commit only what this run wrote, by
explicit path: the task file(s) and any tasks-root scaffolding `task-create`
created; the record, when Phase 2 repaired it or Phase 7 wrote a Disposition
line, with both of its paths and the repaired inbound references when an
Accepted record moved to `never/`; the handoff, design, or idea document and
any README row that goes with it. Never `git add -A`, `-u`, `.`, or `commit
-a`: other work in the tree is not this skill's to sweep up. When Phase 1's
snapshot showed the record already modified, stage only this run's hunks:
build the index entry from HEAD plus this run's edits (`git show
HEAD:<record>` to a scratch copy, apply the edits there, `git hash-object -w`,
then `git update-index --cacheinfo 100644,<blob>,<record>`), leave the working
tree as it is, and say in the report whose edit was left unstaged.

Classify the run as `task-finalize` does, but the exit decides it. A task,
handoff, design, or idea exit always authors prose the user has not seen
verbatim — a Context, a Recommended solution, a document — so those runs are
**authored-content**: name what was authored, point the user at the staged
diff in their IDE, and do not paste it into the conversation. A Disposition
exit is **self-contained** when its sentence is the Recording line's text and
nothing else was authored; a record repair from Phase 2 makes it
authored-content.

Pick the message from the first row that applies:

| Exit | Message |
|---|---|
| Tasks | `docs(problems): plan <slug> into <task-name>` (or `into <n> tasks`) |
| Handoff | `docs(problems): hand off <slug> to <owner/repo>` |
| Design | `docs(problems): design for <slug>` |
| Disposition | `docs(problems): accept <slug>` or `docs(problems): defer <slug>` |

Make the commit offer as a yes/no capture. Self-contained: `Yes — commit now`
(recommended) or `No — leave staged for review`. Authored-content: `Yes —
reviewed, commit now` or `No — leave staged for review`, neither marked
recommended. On Yes, commit with the pathspec and report the hash; on No, say
the changes are left staged. Either way the run ends there: this skill never
pushes and never offers to.

Then relay `task-create`'s deferred offer: run `task-finalize` on the new
task(s) now, or leave them for later. Then, when Phase 4 held incidental
defects, list them one line each and offer to capture any as a thought
(`thought-create`) or a record (`problem-create`); the user picks, and
nothing is captured unasked. This is the first time the user hears of them.

---

## Report

The reader has just finished the interview and is tired of deciding: lead
with what they act on, the artifacts, the commit, and the finalize offer,
and keep the rest short, because it is for the record of the run. Close with:

- **The record and its disposition**, with every artifact written, by path.
- **Gate results**: the status verdict, what already cited the record, and
  whether issues were searched.
- **Subagents**: which lenses ran, what survived adjudication and where it
  landed (candidate, wrinkle, record fix, discarded) — or that they were
  skipped, and why (small; named fix confirmed).
- **Questions resolved**, and any deferred into the task's Open questions.
- **Commit hash**, or "left staged", and a plain statement that nothing was
  pushed — plus, for a blind handoff, that it is not filed until it is.
- **Shared files read**, by path.
- **Found along the way**: the incidental defects Phase 4 held, one line
  each with their evidence, ahead of the capture offer.
