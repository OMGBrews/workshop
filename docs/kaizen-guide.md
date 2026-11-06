# Kaizen — continuous improvement of how we build

The canonical guide to the kaizen practice shared across OMG Brews projects. A project adopts kaizen by adding a `docs/work/kaizen/` directory (a `journal/` tree and a `patterns/` directory, one entry per file) and pointing back here for the methodology. Run `/kaizen-init` to scaffold it. Read this when you want to understand the practice, write a journal entry, or run a patterns review.

## What is this?

Kaizen (改善, "change for the better") emerged from post-WWII Japanese manufacturing — refined inside Toyota as one pillar of the Toyota Production System and now central to Lean — and reached software development through Lean Software Development and the DevOps movement. The substance of kaizen is not the word "improvement"; it's the *shape* of improvement:

- **Compounding small changes beat rare big ones.** A 1% improvement applied a hundred times is more powerful, less risky, and easier to recover from than a 100% rewrite. Big changes carry coordination cost, context loss, and rollback risk; small ones don't.
- **The practitioner closest to the friction is the one whose observations count.** Improvement is bottom-up, not handed down. In our setting that "practitioner" is sometimes a human, sometimes an AI agent in a sub-task, sometimes the tooling itself surfacing a signal — all three are valid sources.
- **Standardize, then improve from the standard.** A standard is the current best-known way, not an end-state. It exists to be the baseline for the next improvement. "We already documented that" is not a stopping condition.
- **Process is a product.** The way you build is itself something you build. The Plan-Do-Check-Act cycle you'd apply to a feature applies to the process: define the way of working, do it, check whether it worked, act on what you learned.
- **Respect for people.** Friction is a signal that *the system* needs adjustment, not a confession that the practitioner failed. A journal entry is the practitioner doing their job by surfacing what didn't work.

### Why this fits OMG Brews projects

These projects share three properties that amplify kaizen's leverage:

- **Heterogeneous practitioners.** Humans, multiple AI agents, sub-agents, and tooling all participate in producing work. Friction lives at the seams between them — handoffs, prompt misreads, worktree races, context loss between sessions. None of those seams are visible in git history alone.
- **The "machine" is documentation.** Instruction files (`AGENTS.md`, and `.claude/rules/` for Claude Code), skills, check scripts, memory feedback files, and style guides are the executable specification of how we work. Improving any of them improves *every* future session — a single-line edit can compound across hundreds of subsequent runs.
- **High session volume with AI assistance.** Even small per-iteration friction (a wrong default, an ambiguous instruction, a misread convention) costs many minutes per day when multiplied across sessions. Catching and standardizing those small wins is where the leverage is.

### Scope

Kaizen exists to improve **how we build** — the collaboration loops between humans, AI agents, and tooling. It is *not* a place for feature concepts, capability ideas, product gaps, or "the X feature should also do Y" — those belong wherever the project tracks future work (e.g. `docs/work/tasks/` or a planning/ideas area). Keeping the boundary tight is what lets the journal stay useful as a process-improvement signal: mixing in feature ideation dilutes it and makes patterns harder to extract.

## The two collections a project keeps

| Collection | Lives in the project at | Description |
|------------|-------------------------|-------------|
| Journal | `docs/work/kaizen/journal/YYYY-MM/YYYY-MM-DD-<slug>.md` | Running log of friction, errors, and lessons — **one entry per file**. Content-immutable after the one-time citation adoption below: an entry is written once and not routinely revised, but it does not live forever — see *The journal's lifecycle* below. |
| Patterns | `docs/work/kaizen/patterns/<slug>.md` | Recurring themes distilled from the journal, with mitigations and status — **one pattern per file**. Present-tense synthesis. |

**One entry per file, filed under a year-month directory.** A journal grows forever, so a single file eventually charges every reader the whole history to read one lesson, and its prepend-at-top convention makes the first lines a standing merge conflict between concurrent sessions. Month directories keep any one listing browsable at the ~30-entries-per-month a busy project generates; per-file entries make concurrent journaling conflict-free and give each entry its own git history.

There is **no index file**. `ls` is the index, and `grep -h '^# ' docs/work/kaizen/journal/*/*.md` lists every title. An index that must be hand-updated on every entry is a drift liability, and nothing loads the journal wholesale, so it would buy nothing. The singleton watchlist introduced below is not an index and must not be allowed to become one: an index is **per-entry and exhaustive**, so every write to the journal is a write to it and it drifts by default; the watchlist is **per-review and curated** — it holds only the entries a review could not match, it is written by one skill at one moment, and it shrinks as entries cluster or age out. The distinction is what stops it inheriting the drift liability.

A project's `docs/work/kaizen/README.md` is a short pointer back to this guide — the methodology is shared and lives here, so it improves in one place rather than drifting across repos. Repos still on the older single-file layout (`journal.md` + `patterns.md`) convert with `workshop/Tools/migrate-kaizen-journal.sh`; it is idempotent and refuses rather than dropping an entry it cannot file.

## Journal citations and one-time adoption

Journal entries cite **task briefs, problem records, and kaizen patterns by
backticked slug, never by path or Markdown link**. Name the document type and
repository where needed to identify it: task `bound-provider-concurrency` in
`owner/repo`, problem `unbounded-provider-concurrency`, or pattern
`verify-before-reporting`. This follows [handoff citations](cross-repo-handoffs.md#citing-one).
A slug survives a bucket move or retirement; git history recovers the document.

This rule is specific to those three targets. **Links to journal evidence stay
real links**, including journal-to-journal links and artifact Evidence lists.
Their citation gate still prevents deleting an entry with a surviving citer.
Other durable documentation links are unchanged.

### Adopt existing entries once

Existing entries are immutable except for this explicit, one-time citation
migration. Complete adoption before moving or retiring a document with legacy
journal links; do not treat each retirement as permission to edit history.

1. Inventory links in the consumer's entire journal, including reference-style
   links, bucketed and legacy paths, fragments, and cross-repository links.
   Resolve each destination relative to its source (or reference definition)
   and classify the target as task, problem, pattern, journal evidence, or other.
   Inspect actual targets; a matching word in a URL is not classification.
2. Establish the target's slug, type, and repository. For an already missing
   target, inspect its owning repository's git history at the cited path
   (`git log --all -- <path>` and `git show <commit>:<path>`), following moves
   where necessary. Record the historical revision used. Do not guess from a
   broken path alone: unresolved or ambiguous identities remain listed as
   adoption blockers until evidence settles them.
3. Convert only citations to the three retirable types. Preserve the descriptive
   link text and all surrounding historical wording, adding the identified
   backticked slug and type/repository as needed. For example, a link labeled
   “active task” becomes “active task (task `bound-provider-concurrency`)”.
   Preserve cross-repository identity even when slugs happen to be unique today.
   For reference-style links, convert the affected uses and remove only unused
   definitions; retain definitions still needed by other links. Preserve any
   meaningful section description in prose. Do not rewrite unrelated prose or
   convert links to journal evidence.
4. Review the complete diff against the inventory. Record the migration and its
   explicit immutability exception in git, with the target mappings and any
   history evidence in the commit body or adoption record. Align local seeded
   guidance with this policy without discarding deliberate local rules.
5. Run the consumer's required whole-tree link check with the migrated files in
   its checked set (stage new files where the check reads tracked paths). Record
   its actual result. Adoption is complete only when the inventory is resolved
   and the required check passes; repair unrelated failures through their normal
   owners, never by broad exclusions or weaker missing-target checks.

After adoption, surviving entries remain byte-for-byte unchanged during moves
and retirement. A legacy link discovered later is incomplete adoption: stop the
operation and finish the recorded migration first. Do not keep fixed records as
redirects or evidence archives to avoid adoption.

## The journal's lifecycle

A journal that only ever grows does not make the *review* slower — a review works from a window, so its read stays bounded however large the corpus gets. What it degrades is **matching**. An entry becomes a pattern when a second instance of it arrives, and if the first instance sits months outside the window, a windowed review cannot see it: the pair that would have revealed the theme is one entry in the window and one entry nobody will read again. So every entry has an end of life, and its exits are pattern graduation, review of a problem-retirement receipt, and watchlist age-out.

### Consumed by a pattern — deleted on graduation

A pattern cites journal entries as evidence. When its lesson is incorporated
into a verified standard and the pattern is deleted, remove its evidence entries
in the same change only if the citation check below finds no surviving citer.
Capture that evidence list before deleting the pattern. Earlier deletion breaks
live evidence links; leaving cleanup to memory strands the evidence.

A problem may also cite journal evidence, but fixing its flaw does not decide
whether those incidents still teach something. Problem retirement follows the
[problem lifecycle](problem-lifecycle.md), preserves entries, and supplies the
receipt below. Kaizen review owns the subsequent retention decision.

### Problem retirement receipts

`problem-resolve` writes one receipt only when the retiring problem cites journal
evidence. Store it at `docs/work/kaizen/pending-problem-reviews/<problem-slug>.md`
in the same staged change and eventual commit as the problem deletion. Create
that directory on demand; do not initialize the rest of Kaizen just to retire a
problem. A receipt is a pending handoff, not a journal entry, pattern, or archive.

Each receipt opens with a scope sentence and records:

- The problem slug and its repository-relative former path as code, not a dead
  Markdown link; include repository identity for cross-repository evidence.
- A full commit SHA whose tree contains the record before retirement, and
  whether the retired working copy differed from that revision. For an untracked
  record say that no historical revision exists; the evidence list still follows.
- Every cited journal entry, with its title and a relative link resolving from
  the receipt, including entries cited in prose. Resolve ambiguous identities
  before retirement; never silently drop missing evidence.
- A short factual retirement reason and `Pending Kaizen review`; do not decide
  that the entries are disposable or invent process lessons.

Do not overwrite an existing receipt. If it concerns the same still-live record,
reconcile its provenance and evidence explicitly; if it is an earlier retirement
of a reused slug, use `<problem-slug>-<source-short-sha>.md` and check that path
for collision too. Keep the receipt in the retiring repository. For external
evidence, retain it and record the owning repository and required handoff in the receipt rather
than editing or deleting its journal. Discharge that part only after its owner
accounts for retention; sending a message requires separate authorization.

Every `kaizen-review` reads **all pending receipts**, independently of its date
window, including when that window is empty. Read their linked entries and
classify each one before removing a receipt. Deduplicate entries appearing in
several receipts or in the normal window; one retention decision must account
for all their live citers. A singleton newly retained from a receipt is not aged
out in that same review merely because its incident is old.

- A remaining lesson joins a pattern or becomes a singleton watch line. Apply
  the normal multi-observation rule for patterns; the fixed defect alone is not
  a reason to create another problem. Keep the entry.
- Another live artifact cites the entry: retain it and name that owner. The
  receipts being discharged in this same candidate are not vetoes; receipts
  remaining pending are. Decide shared entries once against the final candidate,
  so two receipts cannot each defer ownership to the other and then both vanish.
- The incident has no remaining lesson to carry forward: explicitly explain that
  judgment, run both citation searches, and delete only if no live citer remains.

Only after every entry has a recorded outcome, remove the receipt in the same
change as any new pattern/watchlist references or entry deletions. Unreadable
entries, uncertain lessons, or unavailable external owners leave the receipt
pending with the unresolved reason; they never disappear merely because a review
ran. Surviving journal entries remain byte-for-byte unchanged. Report retained
and deleted entries and the discharged or still-pending receipt paths.

This bounded inbox replaces the former same-commit problem cascade. It keeps
retirement independent from Kaizen review without losing the evidence list.
Pattern graduation retains its existing same-change cascade.

### The citation gate uses a check, not a memory

Before removing an entry, ask whether anything else still points at it:

```bash
grep -rn "2026-07-14-tab-delimited-jq-output-silently-collapsed-an-empty-field" --exclude-dir=.git docs/
grep -rn "tab-delimited .jq. output silently collapsed" --exclude-dir=.git docs/   # the prose form
```

Any hit from something still live — another pattern, a problem document, a task,
an instruction file, a planning doc, **or another journal entry** — keeps the
entry. Journal evidence links remain real links, so an inbound citation to a
consumed entry vetoes its deletion. This differs from slug citations to retired
tasks, problems, and patterns, which survive unchanged. (In a workspace of
gitignored sibling clones, name the directories explicitly — a recursive grep
from the root silently searches one repo.)

**The second grep is not optional, and it is why "link evidence by relative path" is load-bearing rather than stylistic.** The check matches a filename, so an artifact citing an entry the way the pattern format warns against — `2026-07-14 — Perl mojibake`, a bare date and a phrase — is invisible to it, and the entry it depends on is deleted out from under it. Measured, not hypothetical: at the time this section was written hq's own verification pattern cited 10 of its 14 occurrences in exactly that form, and a filename grep found none of them. Where you find a prose citation in an editable artifact, repair it to a link; do not delete the entry. A prose citation from another journal entry keeps the target without editing the citer.

### Unmatched — the watchlist, and age-out

An entry that clusters with nothing is a **singleton**: possibly the first instance of a real pattern, possibly a one-off. It is evidence for nothing, so no artifact will ever bring it back into view, and a windowed review three months later will never see it. Naming it in a review report is not enough — the report is a chat message and it is gone by the next pass. It goes on the watchlist instead.

The watchlist is `docs/work/kaizen/singletons.md`, a sibling of `journal/` and `patterns/`, one line per singleton:

```markdown
- [2026-07-14 — tab-delimited jq output silently collapsed an empty field](journal/2026-07/2026-07-14-tab-delimited-jq-output-silently-collapsed-an-empty-field.md) — a positional format cannot express an absent field, so a shifted row still parses as data
```

Title, relative link, and the root cause in one line. The root cause is the part that does the work — it is what a future review matches its window against, and it is the reason the file replaces re-reading the corpus rather than merely indexing it. `/kaizen-review` is its only writer, and it creates the file the first time a review needs one; there is no scaffold for it, because an empty pre-created watchlist is one more file to drift.

A review reads the watchlist alongside `patterns/` and matches its window against both. A windowed entry that matches a watch line **is** the second instance that line was waiting for: the pair becomes a pattern (or a problem document, if the cluster is flaw-shaped), both entries are consumed by it, and the watch line is dropped — a line duplicating a pattern's Evidence list is precisely the drift the watchlist is not.

A watch line whose entry is roughly **a quarter** old — read the date off the filename, and judge it, rather than counting days — **ages out**: line and entry deleted together, behind the same citation check. If the check finds a live citation, the entry is consumed rather than unmatched, so drop the line, keep the entry, and say so in the review report; its retention follows the lifecycle of the artifact citing it.

Three months is a threshold, not a discovery. An entry that has waited a quarter for a sibling is not one a review is still likely to match, and keeping it charges every future review a line to read for a match that is not coming. Nothing is ever moved to an `archive/` directory on the way out: git is the archive (`git log --diff-filter=D`, `git log -S`), a second location is a second place to search, and this is how tasks and patterns already die.

The first review to write a watchlist has a one-time job the others do not: seed it from the **whole corpus**, not from its window. Every singleton earlier reviews named lives only in reports that no longer exist, and those are exactly the entries the file is for.

### Who performs the deletion

`kaizen-review` owns journal deletion: pattern cascades, pending problem-receipt
review, and watchlist age-out, all behind the citation check. `problem-resolve`
owns problem retirement and preserves the journal. These operations may happen
in the same session when requested, but neither implies the other.

No full-corpus orphan sweep is needed: receipts preserve the exact evidence
lists outside the normal review window. A review must account for its inbox
before it claims no pending work.

## How it works — the PDCA cycle

Kaizen runs on **Plan → Do → Check → Act**. The cycle maps to specific artifacts:

| PDCA stage | Where it happens |
|---|---|
| **Plan** — define a way of working | `AGENTS.md` rules, skills, check scripts, style guides, memory feedback files, procedures — and, Claude Code only, `.claude/rules/` files and hooks (the destination ladder below ranks these by portability) |
| **Do** — apply that way of working | Day-to-day sessions; humans and AI agents act on the standards |
| **Check** — capture friction when standards misfire | A new entry file in `journal/` (the `/session-end` skill is the per-session checkpoint for this) |
| **Act** — change the standards so it doesn't recur | Patterns distilled into `patterns/`, then graduated into the Plan-stage artifacts |

Each graduation closes one loop and starts the next: the next session inherits the change and may surface its own friction.

### Recording (the Check stage)

When you encounter friction during work — unexpected errors, multiple attempts needed, confusing behavior, something that took longer than it should — write an entry file into `journal/`.

**When to write an entry**

- Something takes significantly longer than expected
- A fix requires multiple attempts
- A convention should have existed earlier
- An approach that seemed right turned out wrong
- Orchestration or tooling causes friction
- A pattern repeats for the third time

**When NOT to write an entry**

- Feature concepts or capability ideas (that's the planning/ideas area — see *Scope* above)
- Routine work that went smoothly (that's just git history)
- Anything already captured in a memory feedback file

**Writing useful entries**

An entry compounds when it lets a future reader (or a future AI session) recognize the same situation before they're stuck in it. Three things distinguish entries that compound from ones that evaporate:

- **Name the root cause, not just the symptom.** The first observable thing was usually downstream of something earlier. *"Sub-agent committed to main instead of its worktree"* is a symptom; *"spawning a worktree-isolated agent from inside an existing worktree silently no-ops, so the child runs in the parent's tree"* is the cause. Cause-level entries graduate into rules; symptom-level ones don't.
- **Be concrete about the situation.** A future reader matches against specifics — exact tool, specific flag, what the agent was told, what was expected vs. what happened. Vague entries (*"the prompt was confusing"*) don't help anyone match.
- **The Lesson field is load-bearing.** It's the bridge between this entry and the rule that should exist. If you can phrase the Lesson as a one-line `AGENTS.md` rule, a check, or a style-guide bullet, the graduation path is already visible.

**Where the entry goes**

One file per entry, at `docs/work/kaizen/journal/YYYY-MM/YYYY-MM-DD-<slug>.md` — create the month directory if it does not exist. The slug is the title lowercased with every run of non-alphanumeric characters replaced by a hyphen, capped at ~60 characters on a word boundary. The full date stays in the filename even inside the month directory, so a filename remains self-describing when it is linked from a pattern, quoted in a PR, or grepped on its own.

**Entry format**

```markdown
# [short title]

**Context**: What we were trying to do
**What happened**: What we tried, what went wrong or right
**Friction**: Specific errors, delays, or confusion encountered
**Lesson**: What we learned; what to do differently
**Action**: Concrete change made or to be made (commit hash, task created, etc.)
```

The date is carried by the filename, not repeated in the heading, and entries take no frontmatter — nothing parses metadata off them.

### Analysis (the Act stage)

Every ~2 weeks or after a sprint, review recent journal entries (the newest month directories). Look for entries that share a root cause, and route each cluster by what it is:

- **A standing, fixable flaw** — broken tooling, an ungated mirror, a script defect: anything where "verified gone" is a meaningful endpoint — becomes a **problem document** filed from `.agents/skills/problem-create/_TEMPLATE.md` under `docs/work/problems/` (whose README is seeded from `docs/templates/problems/README.md`), plus a task where the fix is already concrete. It does not become a pattern: a pattern tracks a *tendency*, a problem tracks a *state*, and the problem lifecycle — persists until the flaw is verified gone; a task completing is not the trigger — is the right home for anything a fix can end.
- **A recurring tendency whose countermeasure is statable today** — graduate it, in the same pass, under the contract below.
- **A recurring tendency not yet statable** — create or update `patterns/<slug>.md` with evidence, mitigation, and status, and let it accumulate until it is.

Graduation writes the lesson into its Plan-stage destination. Destinations are enforcement points, ranked by portability — pick the highest rung that can actually enforce the rule:

  - **A check script** — runs identically in every harness and in CI; when a landing gate requires its evidence, the friction becomes a failing check rather than advice a reader can skip. *Example: a `make check` stage that fails when the friction's signature reappears.*
  - **A skill** under `.agents/skills/` — discovered by every spec-compliant harness; the home for a codified procedure invoked by name. *Example: `kaizen-review`, which turns journal synthesis and pattern graduation into a repeatable procedure.*
  - **A rule in `AGENTS.md`**, or a doc it links — read at session start by every harness, so it is the default home for conventions and one-line rules. Style guides and procedures live at this rung. *Example: a bullet in `AGENTS.md` naming the convention, with the detail in a linked style guide.*
  - **A `.claude/rules/` file or a hook** — Claude Code only, acceptable in two shapes: as the *bridge* to neutral content (a universal rule in a linked doc gets a plain link in `AGENTS.md` and a symlink in `.claude/rules/`, per the placement table in [`harness-agnostic-repos.md`](harness-agnostic-repos.md)), or as a consciously Claude-only enforcement where only a hook can do the work — a `PreToolUse` block that fires without anyone having to remember is genuinely that. What it may never be is the only home of a fleet rule. *Example: a SessionStart hook wrapping a plain bootstrap script that any harness can also run.*

Memory feedback files sit off the ladder: they persist AI-specific corrections across sessions in one harness, which is exactly their job — but a fleet rule that lives only there is invisible everywhere else.

Graduate in one pass, in this order: **write the destination, verify it from the reader's side, then delete the pattern file — and, in the same commit, the evidence entries it consumed.** Never the reverse, and never across two sessions. Git keeps the history, and a stale pattern competes with the live rule for attention. The cascade into the journal, and the citation check that decides which entries actually go, are in *The journal's lifecycle* above.

- **The write is the risk, not the delete.** Verify by grepping the destination for a distinguishing term of the mitigation — the specific tool, flag, or mechanism the lesson is about — and reading what surrounds it. A graduation recorded but never actually written is how a retired lesson comes back as a fresh incident; that is not hypothetical — it is how occurrence #5 of the verification pattern returned as occurrence #10, 18 days later.
- **Never empty a pattern's Mitigation field as a graduation step.** A pattern is deleted whole or left whole. Replacing the bullets with "graduated to X" destroys the only text a later reader could check X against, and it is what made the 2026-07-14 loss undetectable. There is no intermediate state.
- **A graduation is never deferred to a task.** The session that holds the mitigation text is the only one that can pick the grep term, so it is the only one that can honestly verify the write. If a settled pattern also implies an artifact that must be *built* — a check, a boundary control, a hook — state the rule now, delete the pattern now, and file the build as an ordinary task (or a problem document, where the flaw wants evidence gathered before scoping) on its own merits, quoting the pattern's evidence into the brief before the file goes away. The pattern's deletion is not contingent on that work: an unbuilt artifact is missing enforcement, not a missing lesson.
- **If the rule cannot be stated yet, this is not a graduation.** A pattern with an open policy question (what threshold, which mechanism) stays `Active`, and the question belongs to whichever task owns it.

`/kaizen-review` is this section as a skill — run it when the review is due rather than reconstructing the procedure by hand.

**Pattern format**

One file per pattern, at `docs/work/kaizen/patterns/<slug>.md`:

```markdown
# [Pattern name]

**Pattern**: The recurring shape of the friction, stated generally.

**Evidence**: The journal entry files that exhibit it, linked by relative path.

**Mitigation**: What reduces or removes it.

**Status**: Active | Mostly resolved
```

There is deliberately no "graduated" and no "graduating" status. A graduated pattern is deleted in the pass that graduates it, so the value would be unreachable — and the one time such a value was used, it licensed marking a pattern Resolved on the strength of a graduation that had not happened. An in-flight status has the same defect one step later: a claim with full confidence, no visible age, and nothing observing whether its owner ever finished.

Link evidence as `[2026-07-12 — two log dirs](../journal/2026-07/2026-07-12-two-log-dirs-one-relative-path.md)` rather than by date alone: a busy day carries several entries, and a bare date no longer identifies one. Since the lifecycle above made a filename grep the thing that decides whether an entry survives, this is no longer only about legibility — an evidence citation written as prose is a claim the citation check cannot see, and the entry behind it will be deleted while the pattern still depends on it.

## See also

- [Kaizen reference](kaizen-reference.md) — the outside sources behind this practice and how their concepts map onto it
- [Problem resolve reader fixture](problem-resolve-reader-fixture.md) — controlled evidence, source-resolution, and retirement trials

- `docs/templates/kaizen/` — the starter scaffold: a per-repo `README.md` plus `journal/` and `patterns/` directories
- `Tools/migrate-kaizen-journal.sh` — converts a repo from the older single-file `journal.md` / `patterns.md` layout
- The `/kaizen-init` skill — scaffolds `docs/work/kaizen/` into a project and adds the instruction-file pointer
- The `/session-end` skill — the per-session Check-stage checkpoint that captures friction before it evaporates
- The `/kaizen-review` skill — the periodic Act-stage pass: the *Analysis* section above, run. It clusters the entries written since the last review into `patterns/`, walks each graduation with you before applying it, and is the sole writer of the singleton watchlist and the sole executor of the pattern side of *The journal's lifecycle*
- The `/problem-resolve` skill — verifies and retires a problem under the separate [problem lifecycle](problem-lifecycle.md), preserving journal evidence and writing a pending review receipt when needed
