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
- **The "machine" is documentation.** Instruction files (`AGENTS.md`, bridged into `CLAUDE.md`), skills, check scripts, memory feedback files, and style guides are the executable specification of how we work. Improving any of them improves *every* future session — a single-line edit can compound across hundreds of subsequent runs.
- **High session volume with AI assistance.** Even small per-iteration friction (a wrong default, an ambiguous instruction, a misread convention) costs many minutes per day when multiplied across sessions. Catching and standardizing those small wins is where the leverage is.

### Scope

Kaizen exists to improve **how we build** — the collaboration loops between humans, AI agents, and tooling. It is *not* a place for feature concepts, capability ideas, product gaps, or "the X feature should also do Y" — those belong wherever the project tracks future work (e.g. `docs/work/tasks/` or a planning/ideas area). Keeping the boundary tight is what lets the journal stay useful as a process-improvement signal: mixing in feature ideation dilutes it and makes patterns harder to extract.

## The two collections a project keeps

| Collection | Lives in the project at | Description |
|------------|-------------------------|-------------|
| Journal | `docs/work/kaizen/journal/YYYY-MM/YYYY-MM-DD-<slug>.md` | Running log of friction, errors, and lessons — **one entry per file**. Content-immutable: an entry is written once and never revised, but it does not live forever — see *The journal's lifecycle* below. |
| Patterns | `docs/work/kaizen/patterns/<slug>.md` | Recurring themes distilled from the journal, with mitigations and status — **one pattern per file**. Present-tense synthesis. |

**One entry per file, filed under a year-month directory.** A journal grows forever, so a single file eventually charges every reader the whole history to read one lesson, and its prepend-at-top convention makes the first lines a standing merge conflict between concurrent sessions. Month directories keep any one listing browsable at the ~30-entries-per-month a busy project generates; per-file entries make concurrent journaling conflict-free and give each entry its own git history.

There is **no index file**. `ls` is the index, and `grep -h '^# ' docs/work/kaizen/journal/*/*.md` lists every title. An index that must be hand-updated on every entry is a drift liability, and nothing loads the journal wholesale, so it would buy nothing. The singleton watchlist introduced below is not an index and must not be allowed to become one: an index is **per-entry and exhaustive**, so every write to the journal is a write to it and it drifts by default; the watchlist is **per-review and curated** — it holds only the entries a review could not match, it is written by one skill at one moment, and it shrinks as entries cluster or age out. The distinction is what stops it inheriting the drift liability.

A project's `docs/work/kaizen/README.md` is a short pointer back to this guide — the methodology is shared and lives here, so it improves in one place rather than drifting across repos. Repos still on the older single-file layout (`journal.md` + `patterns.md`) convert with `devtools/Tools/migrate-kaizen-journal.sh`; it is idempotent and refuses rather than dropping an entry it cannot file.

## The journal's lifecycle

A journal that only ever grows does not make the *review* slower — a review works from a window, so its read stays bounded however large the corpus gets. What it degrades is **matching**. An entry becomes a pattern when a second instance of it arrives, and if the first instance sits months outside the window, a windowed review cannot see it: the pair that would have revealed the theme is one entry in the window and one entry nobody will read again. So every entry has an end of life, and there are exactly two ways to reach it.

### Consumed — deleted with the artifact that absorbed it

An entry is **consumed** when a live artifact cites it as evidence: a `patterns/<slug>.md`, or a `docs/work/problems/<slug>.md`. Its lesson now lives somewhere present-tense, and the entry is the receipt. When that artifact dies — a pattern graduated and deleted, a problem verified gone and deleted — its evidence entries are deleted **in the same commit**, provided nothing else live still cites them.

Same commit, not later and not earlier, and both halves of that matter:

- **Earlier breaks a live evidence link.** While the pattern or problem is alive, its Evidence list is the thing a reader checks it against; deleting the entries out from under it leaves a document making claims whose sources are gone, and in repos with a required doc-link check (llmkit-dev) it turns CI red.
- **Later never happens.** The pass that deletes the artifact is the only one holding its evidence list. Once the file is gone, nothing anywhere records which entries it had absorbed — recovering that means reading it out of git history, which nobody will think to do.

### The citation gate uses a check, not a memory

Before removing an entry, ask whether anything else still points at it:

```bash
grep -rn "2026-07-14-tab-delimited-jq-output-silently-collapsed-an-empty-field" --exclude-dir=.git docs/
grep -rn "tab-delimited .jq. output silently collapsed" --exclude-dir=.git docs/   # the prose form
```

Any hit from something still live — another pattern, a problem document, a task, a CLAUDE.md, a planning doc, **or another journal entry** — keeps the entry. The journal is included deliberately and it is not symmetric with the pattern-deletion rule, which tells you an entry linking a graduated pattern is *expected* to dangle: you may not edit an entry, so you can never repair a link *out of* one, which leaves not-deleting as the only way to keep the tree link-clean. An inbound link from an entry is therefore a veto, exactly as a citation from a pattern is. (In a workspace of gitignored sibling clones, name the directories explicitly — a recursive grep from the root silently searches one repo.)

**The second grep is not optional, and it is why "link evidence by relative path" is load-bearing rather than stylistic.** The check matches a filename, so an artifact citing an entry the way the pattern format warns against — `2026-07-14 — Perl mojibake`, a bare date and a phrase — is invisible to it, and the entry it depends on is deleted out from under it. Measured, not hypothetical: at the time this section was written hq's own verification pattern cited 10 of its 14 occurrences in exactly that form, and a filename grep found none of them. Where you find a prose citation, repair it to a link; do not delete the entry.

### Unmatched — the watchlist, and age-out

An entry that clusters with nothing is a **singleton**: possibly the first instance of a real pattern, possibly a one-off. It is evidence for nothing, so no artifact will ever bring it back into view, and a windowed review three months later will never see it. Naming it in a review report is not enough — the report is a chat message and it is gone by the next pass. It goes on the watchlist instead.

The watchlist is `docs/work/kaizen/singletons.md`, a sibling of `journal/` and `patterns/`, one line per singleton:

```markdown
- [2026-07-14 — tab-delimited jq output silently collapsed an empty field](journal/2026-07/2026-07-14-tab-delimited-jq-output-silently-collapsed-an-empty-field.md) — a positional format cannot express an absent field, so a shifted row still parses as data
```

Title, relative link, and the root cause in one line. The root cause is the part that does the work — it is what a future review matches its window against, and it is the reason the file replaces re-reading the corpus rather than merely indexing it. `/kaizen-review` is its only writer, and it creates the file the first time a review needs one; there is no scaffold for it, because an empty pre-created watchlist is one more file to drift.

A review reads the watchlist alongside `patterns/` and matches its window against both. A windowed entry that matches a watch line **is** the second instance that line was waiting for: the pair becomes a pattern (or a problem document, if the cluster is flaw-shaped), both entries are consumed by it, and the watch line is dropped — a line duplicating a pattern's Evidence list is precisely the drift the watchlist is not.

A watch line whose entry is roughly **a quarter** old — read the date off the filename, and judge it, rather than counting days — **ages out**: line and entry deleted together, behind the same citation check. If the check finds a live citation, the entry is consumed rather than unmatched, so drop the line, keep the entry, and say so in the review report; it will die with whatever cites it.

Three months is a threshold, not a discovery. An entry that has waited a quarter for a sibling is not one a review is still likely to match, and keeping it charges every future review a line to read for a match that is not coming. Nothing is ever moved to an `archive/` directory on the way out: git is the archive (`git log --diff-filter=D`, `git log -S`), a second location is a second place to search, and this is how tasks and patterns already die.

The first review to write a watchlist has a one-time job the others do not: seed it from the **whole corpus**, not from its window. Every singleton earlier reviews named lives only in reports that no longer exist, and those are exactly the entries the file is for.

### Who performs the deletion

Whoever deletes the absorbing artifact deletes the entries it absorbed. `/kaizen-review` owns the pattern cascade and the age-out, because it owns pattern deletions and the watchlist. A **problem document's** cascade belongs to whichever session verifies the flaw gone and deletes the document — `/kaizen-resolve` is that session's ritual; run it rather than reconstructing the procedure from this paragraph.

There is no backstop sweep, deliberately. A missed cascade costs one stray entry that now matches nothing; a sweep that walks the whole corpus looking for strays is the unbounded read this lifecycle exists to remove.

## How it works — the PDCA cycle

Kaizen runs on **Plan → Do → Check → Act**. The cycle maps to specific artifacts:

| PDCA stage | Where it happens |
|---|---|
| **Plan** — define a way of working | `AGENTS.md` rules, skills, check scripts, style guides, memory feedback files, procedures — and, Claude Code only, `CLAUDE.md` `@`-imports and hooks (the destination ladder below ranks these by portability) |
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

- **A standing, fixable flaw** — broken tooling, an ungated mirror, a script defect: anything where "verified gone" is a meaningful endpoint — becomes a **problem document** (`docs/work/problems/` — seeded from `devtools/docs/templates/problems/README.md`), plus a task where the fix is already concrete. It does not become a pattern: a pattern tracks a *tendency*, a problem tracks a *state*, and the problem lifecycle — persists until the flaw is verified gone; a task completing is not the trigger — is the right home for anything a fix can end.
- **A recurring tendency whose countermeasure is statable today** — graduate it, in the same pass, under the contract below.
- **A recurring tendency not yet statable** — create or update `patterns/<slug>.md` with evidence, mitigation, and status, and let it accumulate until it is.

Graduation writes the lesson into its Plan-stage destination. Destinations are enforcement points, ranked by portability — pick the highest rung that can actually enforce the rule:

  - **A check script** — runs identically in every harness and in CI; when a landing gate requires its evidence, the friction becomes a failing check rather than advice a reader can skip. *Example: a `make check` stage that fails when the friction's signature reappears.*
  - **A skill** under `.agents/skills/` — discovered by every spec-compliant harness; the home for a codified procedure invoked by name. *Example: the `kaizen-resolve` skill, which turns the problem-document close-out into a ritual.*
  - **A rule in `AGENTS.md`**, or a doc it links — read at session start by every harness, so it is the default home for conventions and one-line rules. Style guides and procedures live at this rung. *Example: a bullet in `AGENTS.md` naming the convention, with the detail in a linked style guide.*
  - **A `CLAUDE.md` `@`-import or a hook** — Claude Code only, acceptable in two shapes: as the *bridge* to neutral content (a universal rule in a linked doc gets a plain link in `AGENTS.md` and an `@`-import in `CLAUDE.md`, per the placement table in [`harness-agnostic-repos.md`](harness-agnostic-repos.md)), or as a consciously Claude-only enforcement where only a hook can do the work — a `PreToolUse` block that fires without anyone having to remember is genuinely that. What it may never be is the only home of a fleet rule. *Example: a SessionStart hook wrapping a plain bootstrap script that any harness can also run.*

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

- `docs/templates/kaizen/` — the starter scaffold: a per-repo `README.md` plus `journal/` and `patterns/` directories
- `Tools/migrate-kaizen-journal.sh` — converts a repo from the older single-file `journal.md` / `patterns.md` layout
- The `/kaizen-init` skill — scaffolds `docs/work/kaizen/` into a project and adds the CLAUDE.md pointer
- The `/session-end` skill — the per-session Check-stage checkpoint that captures friction before it evaporates
- The `/kaizen-review` skill — the periodic Act-stage pass: the *Analysis* section above, run. It clusters the entries written since the last review into `patterns/`, walks each graduation with you before applying it, and is the sole writer of the singleton watchlist and the sole executor of the pattern side of *The journal's lifecycle*
- The `/kaizen-resolve` skill — the same lifecycle's problem side, run: verifying a `docs/work/problems/` document's flaw gone from the world's side — deleting it, and cascading into the entries it consumed, all behind the citation gate above
