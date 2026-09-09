---
name: kaizen-review
description: Run the kaizen Act stage on demand — read the journal entries since the last review, cluster those that share a root cause, file flaw-shaped clusters as problem docs (docs/work/problems/), distil tendencies into patterns/, and graduate settled patterns into the standards that stop it recurring (a gate, a skill, an AGENTS.md rule, a style guide). Also maintains the journal's lifecycle — unmatched entries go onto the singleton watchlist, a pattern's evidence entries are deleted with it, and watch lines age out past ~a quarter. The periodic counterpart to the session-end skill's per-session Check stage, which refuses this work. Invoke when the patterns review is overdue (~2 weeks or after a sprint), when the journal has grown much faster than patterns/, or when someone asks what recent friction has in common. Every graduation is proposed and only approved ones applied; a journal entry is never edited, only written once and later deleted whole, and nothing is committed or pushed.
---

# Kaizen Review

The **Act** stage of the kaizen PDCA loop, run interactively. The `session-end` skill captures friction into `journal/` as it happens (Check) and is explicitly forbidden from doing more; this skill is what it defers to — the periodic pass that reads the accumulated entries, distils the recurring ones into `patterns/`, and turns settled patterns into standing rules so the friction stops happening.

Two properties shape everything below:

- **The journal is content-immutable.** It is a record of what happened, so this skill never *edits* an entry — not to renumber, not to cross-reference, not to correct. It does end an entry's life: the guide's *The journal's lifecycle* section gives every entry two exits — deleted with the artifact that consumed it, or aged off the watchlist — and both are this skill's to perform. There is no state in between: an entry is written once, and later deleted whole. `patterns/` is the present-tense synthesis; `singletons.md` is the watchlist of entries still waiting for a sibling, and this skill is its only writer.
- **Graduation is the point, and graduation is destructive.** A pattern graduates by having its lesson written into a live standard, its own file deleted, and the entries it consumed deleted with it. Both halves are the human's call, and the delete half is only safe once the write half is verified from the reader's side — see Phase 5.

Repo-agnostic: it works in any project that has adopted kaizen and stops cleanly in one that has not.

**Arguments**: an optional review window: a month directory like `2026-07`, or `all`. With none, the window runs from the last review to now.

---

## Phase 1 — Preconditions

1. **Is kaizen adopted here?** `docs/work/kaizen/` with `journal/` and `patterns/` under it. If it is absent, print `This project has not adopted kaizen — no docs/work/kaizen/ directory. Invoke the kaizen-init skill to scaffold it, then come back.` and **stop**. Do not scaffold, do not offer to; adoption is its own decision and its own skill.
2. **Resolve the guide.** Resolve it by the physical-directory rule ([`skill-path-resolution.md`](../../../docs/skill-path-resolution.md)): `<this skill's physical directory>/../../../docs/kaizen-guide.md` first (follow the symlink before taking `..`), then the repo-root paths kept for repos that mount the docs elsewhere — `<mount>/docs/kaizen-guide.md` from the repo root, under whatever name this repo mounts the tree by, and the project's `docs/work/kaizen/README.md` where it links the guide. If nothing resolves, **degrade rather than stopping**: run the procedure this body carries, and say in the report that the guide was not found and this run is therefore thinner than a full one — the standing rules the guide would have imported are this body's own wording instead of the canonical source.
3. **Read the guide's "Analysis (the Act stage)" section and its "Pattern format" block now.** Not from memory, and not from this file — the procedure, the graduation destinations, and the pattern fields live there and are deliberately not restated here. One source, so the two cannot disagree.

---

## Phase 2 — Choose the window, and say what it is

The argument decides. With none, derive the window from when `patterns/` last moved:

```bash
git log -1 --format='%cs %h %s' -- docs/work/kaizen/patterns/   # last time the synthesis changed
git log -1 --format='%cs %h %s' -- docs/work/kaizen/journal/    # last time an entry was written
```

Entries newer than the `patterns/` date are the window; a month-directory argument (`2026-07`) or `all` overrides it.

**That date is a proxy, and it is imprecise in two known ways — say which one applies rather than presenting it as a review date.** A review that examined everything and changed nothing leaves no trace, so the date can read older than the truth. A commit that only renumbered evidence, or migrated the layout, refreshes it without any review having happened, so it can read newer. Check what the commit it names actually was (`%s` above prints the subject) before treating it as a review.

When the derived window is empty but the journal has grown, prefer widening to reporting "nothing to do": an empty window from a bad proxy is the failure mode here, and re-reading a month is cheap.

Print the window and the entry count before reading anything, so the report's scope is fixed before the analysis can quietly narrow it.

---

## Phase 3 — Read the ground

Three things, in this order:

1. **Every existing pattern file, in full.** `docs/work/kaizen/patterns/*.md` (skip `README.md`). You cannot decide whether an entry joins an existing cluster against a pattern you have only seen the title of, and the whole cost of getting this wrong is a duplicate pattern competing with the real one.
2. **The watchlist, `docs/work/kaizen/singletons.md`, in full.** This is the matching set for everything *outside* the window: one line per entry an earlier review could not cluster, each carrying its root cause precisely so you can match against it without re-reading the corpus. It is short by construction and it is the whole reason a windowed review can still catch a pair whose halves are months apart. A missing file means no review has needed one yet — you will create it in Phase 4. Do **not** substitute a grep over the journal: that is the unbounded read the watchlist exists to replace, and in this workspace a recursive grep silently searches one repo anyway.
3. **Every entry in the window, in full.** Titles are not enough — a root cause is in the **Lesson** and **What happened** fields, and two entries with unrelated titles routinely share one. List them first (`ls docs/work/kaizen/journal/*/*.md`, or `grep -h '^# ' docs/work/kaizen/journal/*/*.md` for titles), then read.

Entries carry no frontmatter and there is no index; `ls` is the index. Discover the month directories by globbing the journal root — never by a recursive search from a parent directory, which in a workspace of gitignored clones silently searches one repo and exits 0.

---

## Phase 4 — Cluster, and write `patterns/`

**A pattern needs two or more entries that share a root cause.** One entry is an entry; writing a pattern for it manufactures a theme the evidence does not support.

The test for "share a root cause": state the cause in one sentence such that both entries are instances of it. If the sentence needs an "or" to cover both, they are two patterns. If the sentence only restates the symptom ("a script failed"), keep reading — the cause is upstream of the first thing anyone noticed.

Sort each windowed entry into exactly one of five outcomes, and account for all of them in the report:

- **Names a standing, fixable flaw** — alone or with siblings → a **problem document**, never a pattern. The discriminator is whether "verified gone" is a meaningful endpoint: broken tooling, an ungated mirror, a script defect qualify; a behavioral tendency does not. File it through the `problem-create` skill, whose canonical `.agents/skills/problem-create/_TEMPLATE.md` supplies the record shape. That skill offers to scaffold `docs/work/problems/` from the tree's `docs/templates/problems/README.md` when needed. A problem persists until the flaw is *verified* gone — a task completing is not the trigger — so it, not a pattern's Status field, owns the fix's lifecycle. Where the fix is already concrete, propose a task alongside.
- **Joins an existing pattern** → add it to that file's Evidence list.
- **Matches a watch line** → the line is a first instance and this entry is its second. Route the pair by what it is — a new `patterns/<slug>.md`, or a problem document if the shared cause is flaw-shaped — citing **both** entries as evidence, and **drop the watch line**. It has done its job, and a line duplicating a pattern's Evidence list is exactly the drift the watchlist is not. This is the outcome the watchlist exists for; a review that never produces one has probably read the file as a list of titles rather than matching against its root causes.
- **Starts a new cluster** with at least one other entry — from the window, or from the watchlist → new `patterns/<slug>.md`.
- **Stays a singleton** → **write a watch line into `docs/work/kaizen/singletons.md`**, in the guide's format: title, relative link, and the root cause in one line. Being a singleton is a normal outcome, not a gap — but "name it in the report and move on" is what made a first instance unfindable a quarter later, so the line *is* the outcome and the report only counts them. Create the file if it does not exist. If this is the first review to write one, seed it from the whole corpus rather than the window (the guide says why) — the singletons earlier reviews named live only in reports that are gone.

Write the file in the guide's format, with evidence linked by relative path **and** title — a bare date does not identify an entry on a day that carried five, and since Phase 5's cascade decides an entry's survival by grepping for its filename, a prose citation is a dependency the gate cannot see.

### Maintaining the watchlist is part of writing `patterns/`, not a separate chore

Three edits, and all three belong to whatever pass caused them:

- A windowed singleton **gains** a line.
- A matched line is **dropped** in the same edit that writes the pattern citing its entry.
- An entry that joins an existing pattern and *was* on the watchlist has its line **dropped** too — it is consumed now, and the pattern's Evidence list is where it lives.

Leaving a stale line behind is not a cosmetic failure: the next review matches its window against these lines, and one that names an already-clustered entry manufactures a duplicate pattern out of a match that was already made.

### Recurrence counts and escalation triggers are not the same thing

Some patterns number their occurrences, and the number is load-bearing: a trigger elsewhere may be defined against it ("if an Nth occurrence lands, convention has failed"). Two rules, and the line between them is the whole point:

- **Counts are yours to maintain.** Adding evidence to a numbered pattern means extending its numbering. The count is defined as the entries above it, so editing the evidence list and leaving the count alone produces a pattern that contradicts itself. Same act, not a separate one.
- **Trigger semantics are never yours to author or change.** The threshold, the escape clause, whether a fired trigger is spent, what replaces it — those are policy. If a count you just updated crosses a documented threshold, or has already crossed one, **flag it in the report** with a pointer to the task that owns the escalation. If no task owns it, propose one rather than deciding it here.

Preserve whatever structure a pattern file already carries — an unusual field, a dated "Previously" paragraph, a `Correction` note. It was put there by someone who had a reason, and normalising it away costs more than the tidiness is worth.

---

## Phase 5 — Propose graduations; apply only what is approved

A pattern is a graduation candidate when its mitigation has settled into something statable as a rule and there is a live artifact to state it in. The guide's "Analysis (the Act stage)" section lists the destinations; pick from those.

**Before proposing, split the pattern into what is statable and what must be built.** A settled pattern usually decomposes into (a) a rule someone can read, and (b) an artifact that enforces it. Propose (a) as the graduation — it lands in this pass. Propose (b) as a separate task or problem document, justified on its own merits, and say in the proposal that the graduation is **not** contingent on it. Do not route the whole pattern to a task because part of it is build work; that is how a lesson ends up in escrow behind a queue. When a spun-off brief carries the pattern's evidence, quote it verbatim rather than linking it — the pattern file will not exist when the work is picked up.

If (a) cannot be stated — the mitigation has an open policy question — this is not a graduation candidate. Leave the pattern `Active` and flag the question to its owning task.

**Decide, then apply.** For each candidate, put the proposal to the human before touching anything (brief first, per the ask-with-briefing rule — the popup shows no code and no reasoning):

1. **Which pattern**, and the one-line lesson it graduates.
2. **The destination file**, and why that one.
3. **The exact edit** — the literal text to be added and where it goes, not a description of it. "Add a rule about X" is not a proposal anyone can approve.
4. **What deleting the pattern file loses** — the evidence list, the occurrence count, any trigger the file carries. If something in it must survive, say where it goes instead.

Apply only the approved ones. A decline leaves the pattern file exactly as it is; do not "partially graduate" by editing the destination and keeping the file, which produces the two competing copies the delete rule exists to prevent.

### Verify the graduation from the reader's side before deleting anything

This is the step that has actually failed here, and it failed silently. A pattern was recorded as graduated into `signal-hygiene.md`, the pattern file was retired on that basis, and the destination never contained the lesson — the content was dropped in transit, so nothing in any later session prevented the identical failure recurring.

So for every graduation, before the deletion:

```bash
grep -n -i "<a distinguishing term from the mitigation>" <destination file>
```

Pick a term that could only appear if the substance landed — the specific tool, flag, or mechanism the lesson is about, never a generic word like "verify". Then **read the surrounding lines**: the grep proves a string is present, and what you need to know is whether a reader arriving cold gets the lesson. A graduation whose substance you cannot find in the destination is not done, and its pattern file is not deleted.

Delete the approved, verified graduations in the same pass, in this order and no other: **edit the destination → run the grep and read it → check inbound links (below) → `git rm <pattern-root>/<slug>.md`, where `<pattern-root>` is `docs/work/kaizen/patterns/` → cascade into the journal (below).** Editing first and stopping loses nothing; deleting first and stopping loses the lesson. Git keeps the history, and a stale pattern competes with the live rule for attention.

Never "retire" a pattern by emptying its Mitigation field and pointing at the destination. Deleted whole, or left whole — the stripped-Mitigation state is what made the 2026-07-14 loss invisible for 18 days, and it leaves the next reader with nothing to check the destination against.

### Check inbound links before deleting

A pattern is linked from journal entries, from other patterns, and from tasks. Before the `git rm`:

```bash
grep -rn "<pattern-slug>" --exclude-dir=.git .
```

(In a workspace of gitignored sibling clones, name the directories explicitly — a recursive grep from the root silently searches one repo.)

Sort the hits into three classes and report all three:

- **Journal entries — expected to dangle; do NOT repair.** An entry linking a pattern that later graduated is a correct record of what was true when it was written, and an entry is never edited. Name them in the report and leave them. (This does *not* generalise to the reverse direction: an entry linked *from* another entry cannot be deleted at all, because the same immutability means you could never repair the link. See the cascade below.)
- **Other patterns and tasks — repoint at the destination** in the same change, so the reader lands on the live rule rather than a dead link.
- **Already wrong before you arrived** — fix either way.

### Cascade the deletion into the journal

The pattern is gone; the entries it consumed go with it, in the same commit. The lesson is in a live standard now and those entries were the receipt — leaving them behind is what makes a review three months out read a corpus that mostly cannot match anything. The rule and its reasoning are the guide's *The journal's lifecycle*; this is where the rule is executed.

For **each entry in the deleted pattern's Evidence list** — read it out of the file before you `git rm`, or out of `git show HEAD:<path>` afterwards; nothing else records it:

```bash
grep -rn "<entry-filename-without-.md>" --exclude-dir=.git docs/     # linked citations
grep -rn "<a distinctive phrase from the entry's title>" --exclude-dir=.git docs/   # prose ones
```

Then:

- **Any hit from something still live** — another pattern, a problem document, a task, a CLAUDE.md, a planning doc, **or another journal entry** — and the entry stays. Say in the report which entry survived and what held it.
- **No live hit** → `git rm <journal-root>/YYYY-MM/<entry>.md`, where `<journal-root>` is `docs/work/kaizen/journal/`.

Three things this order and this pair of greps are built against:

- **Deleting entries before the pattern** leaves a live document whose Evidence links dangle. Same reason the destination is edited before the pattern is removed.
- **The second grep is not decoration.** The first matches a filename, so an artifact citing an entry as `2026-07-14 — Perl mojibake` — bare date, no link — is invisible to it, and you will delete the entry a live pattern depends on. When you find a prose citation, repair it to a link and keep the entry; do not treat the absent filename as absence of a dependency.
- **A journal-to-journal link is a veto, not a dangle.** You may not edit an entry, so a link out of one can never be repaired — not deleting the target is the only move available.

### Age out the watchlist

A watch line whose entry is roughly **a quarter** old — read the date off the filename and judge it; this is not a day count — has waited long enough, and the review that notices is the one that clears it. Run the same two greps as the cascade, then:

- **No live citation** → delete the watch line and `git rm` the entry, together.
- **A live citation** → the entry is consumed rather than unmatched. Drop the line, keep the entry, and name both facts in the report; it dies with whatever cites it.

Age-out needs no human approval and is not proposed like a graduation, because nothing is being decided: no rule is written, no lesson retired. The safety is the one this whole skill runs on — a `git rm` **stages** a deletion and commits nothing, so every removal sits in `git status` for the human to read and revert before it is real. Say how many lines aged out and name the entries, so that read is possible without reconstructing your reasoning.

### Know how far the destination actually reaches

A graduation's blast radius is not obvious from the file you edit:

- **A destination inside the shared tools tree this repo imports** — a doc the repo's `AGENTS.md` links or its `CLAUDE.md` `@`-imports from the mounted tree — loads in every session of this repo, whatever harness. Write it for a reader who has no idea which incident prompted it.
- **A project-local destination** (this repo's `AGENTS.md`, a project skill, a gate script — or, Claude Code only, a `CLAUDE.md` `@`-import or hook) is live the moment it is committed here.
- **The pattern file reaches nobody either.** `docs/work/kaizen/patterns/` is loaded into no session in any repo, while an eagerly-imported destination is loaded into every one. "Keep the pattern until the propagation runs" therefore protects no reader anywhere; it only delays the rule. Report the reach gap; do not hold the deletion open for it.
- **Private shared-tools mount only.** When this repo mounts the private shared-tools tree (conventionally `devtools/`), a graduation into it reaches no consumer by itself: the tree's edges are pinned, so a consumer keeps its recorded pointer until an explicit propagation runs, and outside the workspace index an uncommitted edit there does not survive the next sweep. Say that in the report — "graduated into devtools" means the rule is committed there and is *not yet* in any consumer — and follow the propagation playbook at `<mount>/docs/devtools-propagation.md` (a **new** skill or a renamed one needs its Trap 2c handling on top of the pointer bump). A public mount (`workshop/`) has no such step: the mirror republishes automatically and reach is the mirror's next publish.

---

## Phase 6 — Report

Print a concise block:

- **Window** — the range reviewed, how it was derived, and how many entries it held. If the derived window came from the git proxy, name the commit it keyed off and whether that commit was actually a review.
- **Problems** — filed or updated, one line each with the path (and whether `docs/work/problems/` had to be scaffolded).
- **Patterns** — created, updated, deleted, one line each with the path.
- **Graduations** — applied (destination, and the reader-side check that confirmed it), proposed-and-declined, and any left as candidates for next time.
- **Counts and triggers** — any occurrence count updated, and any threshold crossed, with the task that owns the escalation.
- **Watchlist** — lines **added** (how many, and their titles), lines **matched** into a pattern or problem and dropped, lines **aged out**, and any line dropped while its entry survived on a live citation. If this pass created `singletons.md`, say so and say it was seeded from the whole corpus.
- **Journal deletions** — every entry removed, by cascade or by age-out, naming the artifact that consumed it; and every entry the citation check *kept*, naming what held it. Both halves: a cascade that reports only its deletions cannot be checked.
- **Reach** — for each graduation, whether the destination is live here; on a private `devtools/` mount, whether it awaits a propagation.
- **Uncommitted** — the files changed and the deletions staged, so the human can review and commit them.

Do not commit and do not push. The changes are on disk and named; committing them is the human's.

---

## Hard "do NOT" list

- **Do NOT edit, renumber, or cross-reference a journal entry.** The journal is content-immutable: an entry is written once and never revised. Everything this skill has to say goes in `patterns/`, in `singletons.md`, or in a destination artifact.
- **Do NOT delete a journal entry outside the two exits the guide defines** — the consumption cascade (the artifact that absorbed it is being deleted in the same commit) and watchlist age-out. Tidying, deduplicating, "it's obsolete", "it's covered elsewhere" are not exits; that is destroying the record.
- **Do NOT delete an entry whose citation check found a live citer** — including another journal entry, whose link you could never repair. Keep it and report what held it.
- **Do NOT leave a singleton as a report line only.** It goes on the watchlist, or the review after next cannot see its second instance arrive, which is the whole failure this lifecycle exists to close.
- **Do NOT write a pattern from a single entry.** Two or more sharing a root cause — a windowed pair, or a windowed entry matching a watch line — or it is a singleton and it waits.
- **Do NOT graduate anything the human has not approved**, and do not apply half of an approved graduation.
- **Do NOT defer a graduation to a task, and do NOT write an "in flight" status on a pattern.** The session holding the mitigation text is the only one that can pick the grep term that verifies the write. Build work spun off from a pattern is its own task or problem document; the pattern's deletion never waits on it.
- **Do NOT empty a pattern's Mitigation field.** Delete the file whole or leave it whole.
- **Do NOT delete a pattern file whose substance you could not find in the destination.** The grep-and-read check in Phase 5 is the gate, and its failure mode is exactly the one this rule exists for.
- **Do NOT author or modify an escalation trigger's semantics** — threshold, escape clause, spent-or-live. Flag and point at the owning task.
- **Do NOT restate the guide's pattern format or procedure in this file or in a pattern.** Read the guide; one source.
- **Do NOT run a review from the `session-end` or `session-land` skills.** Those set the cadence expectation and stop there, deliberately.
- **Do NOT commit or push.**

## See also

- [`kaizen-guide.md`](../../../docs/kaizen-guide.md) — the canonical practice: the PDCA cycle, the Act-stage procedure, the pattern format, and the graduation destinations. This skill is that section, run.
- [`kaizen-init`](../kaizen-init/SKILL.md) — scaffolds `docs/work/kaizen/` into a project that has not adopted kaizen.
- [`session-end`](../session-end/SKILL.md) — the per-session Check stage. Its Phase 2c is where the boundary between the two skills is written down.
- Private-tree propagation is deliberately not linked from the public skill;
  public Workshop consumers receive a new pinned version through their normal
  submodule update.
- [`signal-hygiene.md`](../../../docs/signal-hygiene.md) — the standing rule that the reader-side verification in Phase 5 is an instance of: a check whose pass state a no-op also satisfies reports success and ends the investigation.
