---
name: task-reprioritize
description: Rebalance the task queue toward a healthy shape in a single decide-then-apply pass
---

# Reprioritize Tasks

Rebalance the task queue toward the healthy shape defined in [`../task-create/bucket-definitions.md`](../task-create/bucket-definitions.md) § Queue shape, in a single pass. Decide-then-apply instead of asking the user move-by-move: the plan is printed before any move, and staged changes are cheap to revert.

This command owns **planning-bucket moves and deletions** — `task-finalize` owns admission to `finalized/`, `task-move` owns explicit lifecycle moves, and `task-audit` verifies what documents say without moving them. This skill is lightweight: it uses **task-file metadata and bucket state** — no codebase analysis, no test execution. When a `task-audit` run earlier in this conversation produced reprioritization signals, consume them as evidence (see Phase 2); if the documents themselves look stale, run `task-audit` first.

This skill **stages** changes via `git mv` / `git rm` but does **NOT** auto-commit.

**The ranking rules live in [`ranking-rubric.md`](ranking-rubric.md)**, next to this file — area inference, in-flight pinning, readiness and evidence signals, the N/S/L placement categories, the A/B/C coupling tiers, the tiebreakers, and focus weighting. This skill is the rubric's only reader: the `task-next` skill deliberately ranks on its own smaller inline order (decoupled 2026-08-11 for selection speed) and stays aligned by trusting the bucket placement this skill produces, not by re-deriving it. Read the rubric before Phase 1; the phases below cite its sections rather than restating them.

**This pass is weighted by `<tasks>/focus.md` throughout**, not as a closing report line. Every phase below says how focus affected it. The [focus-document contract](../../../docs/focus-document.md) specifies the artifact; the rubric's [Focus weighting](ranking-rubric.md#focus-weighting-tasksfocusmd) section specifies what matches, how much it weighs, and its staleness branches. Focus modifies the mechanics and never overrides them — in particular it never promotes a task whose remaining work cannot start.

## Repo conventions (resolve first)

- **Tasks root**: `docs/work/tasks/` — written as `<tasks>/` below. If none exists, print "No tasks directory found — invoke the `task-create` skill to scaffold one." and stop.
- **Lifecycle buckets**: `<tasks>/finalized/` holds tasks ready for supervised implementation; `<tasks>/queued/` (when it exists) holds tasks the autonomous runner is executing. Both are read-only context for this skill, never sources or targets of moves.
- **Bucket definitions**: [`../task-create/bucket-definitions.md`](../task-create/bucket-definitions.md) — resolve it relative to this file's **physical** directory (follow the symlink before taking `..`, per [`skill-path-resolution.md`](../../../docs/skill-path-resolution.md)), so the sibling is found in the same tree whatever the mount is called; shared with every other task skill so they cannot drift. If even that does not resolve (a partial vendored copy without `task-create`), find the file by mount discovery — the `Tools/sync-skill-symlinks.sh` pattern: this skill's physical location names the mount — and say you fell back.
- **Focus document**: `<tasks>/focus.md` — the owner's statement of what matters right now, at the tasks root beside `README.md`. It sits outside every bucket directory, so a bucket glob never reaches it and it is never a candidate for a move. Format and parsing are specified in the [focus-document contract](../../../docs/focus-document.md); matching, weight, and staleness remain in [`ranking-rubric.md` § Focus weighting](ranking-rubric.md#focus-weighting-tasksfocusmd).
- **`finalized/` and `never/` are excluded from rebalancing**: nothing is moved in or out of either by shape rules. Finalization owns entry to `finalized/`; parking and explicit moves out belong to `task-move`.

---

## Phase 1 — Inventory (including lifecycle buckets as read-only context)

### Read the focus document first

Before globbing anything, read `<tasks>/focus.md` and derive its staleness, per
[`ranking-rubric.md` § Staleness](ranking-rubric.md#staleness). **Check that the file exists
before asking git anything** — `git log` prints a normal recent date for a *deleted*
path, so running it first reports a healthy focus for a document that is gone:

```bash
test -f <tasks>/focus.md && git log -1 --format=%cs -- <tasks>/focus.md
```

Read that command's actual output and name which of the four branches you are on —
current, older than ~30 days, empty (exists but never committed, **never** read as
fresh), or file absent. Whichever it is, it goes in the Phase 2 diagnosis block in as
many words. An absent focus does not make this a quieter run: it makes the run
mechanics-only, and the report has to say so where the focus findings would have gone.

Extract the prose statement and the optional `**Not now:**` line. They are the input to
every focus judgment below.

### Inventory the buckets

List all `.md` files under:

- `<tasks>/now/`
- `<tasks>/soon/`
- `<tasks>/later/`
- `<tasks>/finalized/` *(read-only; ready for supervised implementation)*
- `<tasks>/queued/` *(where it exists — read-only; these are executing, so they are not candidates for moves, only context for area-coupling)*

Exclude `README.md`, `_TEMPLATE.md`, anything inside `queued/blocked/`, and `.gitkeep`.

For each task, read the file and extract:

| Field | Source |
|------|--------|
| **Title** | The H1 title |
| **Status** | Frontmatter `status:` field (`not-started` / `in-progress` / `blocked`) |
| **Effort** | Frontmatter `effort:` field (`small` / `medium` / `large`) |
| **Priority** | Frontmatter `priority:` field (`high` / `medium` / `low`) |
| **Dependencies** | Frontmatter `dependencies:` list (task slugs that must land first) |
| **Created** | Derived from the file's first commit — [`ranking-rubric.md` defines the command](ranking-rubric.md#readiness-and-evidence-signals); there is no `Created:` field |
| **Goal** | First sentence of the `## Goal` (or `## Problem statement`) section |
| **Progress** | Count of `- [x]` vs total `- [ ]` + `- [x]` items inside `## Acceptance criteria`. Sentinel lines `<!-- AC:BEGIN -->` / `<!-- AC:END -->` inside the section are ignored. |
| **Area** | Inferred from `## Scope` — see "Area inference" below |
| **Focus** | The quoted focus sentence covering this task's **In brief**, `## Goal`, or `## Scope`, or `—` for out of focus — see "Focus matching" below |
| **Related-task references** | Other task filenames mentioned in `## Scope`, `## Out of scope`, or `## References` |

### Focus matching

Apply [`ranking-rubric.md` § What counts as in focus](ranking-rubric.md#what-counts-as-in-focus). A task is in focus only when you can quote a **specific sentence** of the focus prose that covers it; record that fragment, because it travels with the judgment all the way to the plan table. No citable sentence means out of focus, which is **neutral** — most of a healthy queue is out of focus and ranks on mechanics alone. Record separately any task named by the `**Not now:**` line: that is the one signal that actively lowers.

With no focus document, every task's Focus cell is `—` and the column header says so; do not silently omit the column.

### Area inference

Apply [`ranking-rubric.md` § Area inference](ranking-rubric.md#area-inference). It covers the repo's optional "Area map" table, the mechanical fallback that descends past generic container directories, multi-area Scope sections (the **primary area** is the most-mentioned), and the title-based fallback when `## Scope` is missing — which must be called out in the Phase 3 rationale so the user can correct it.

Print a compact inventory table grouped by bucket, including the queued section where present:

```
### Now (N) | Soon (N) | Later (N) | Finalized (N, read-only) | Queued (N, read-only)
| Bucket | Task | Status | Effort | Progress | Area | Focus | Goal (1 sentence) |
```

If `now/`, `soon/`, and `later/` are all empty, print "No planning tasks — nothing to rebalance." Report finalized and queued counts as read-only context, then stop.

---

## Phase 2 — Diagnose Bucket Shape

Compute current counts and compare to the **soft targets** [`../task-create/bucket-definitions.md`](../task-create/bucket-definitions.md) § Queue shape defines, with the tolerances this skill adds:

| Bucket | Target | Tolerance |
|---|---|---|
| `now/` | 3 | over-target when count > 4; under-target when count < 3 |
| `soon/` | 3 | over-target when count > 4; under-target when count < 3 |
| `later/` | rest | no target — receives whatever's left |

Tolerance allows ±1 around the target so a 4-task `now/` is not noisily flagged. Beyond ±1, flag the bucket.

Also evaluate the **readiness signals** and the **evidence-based signals** in [`ranking-rubric.md` § Readiness and evidence signals](ranking-rubric.md#readiness-and-evidence-signals) — the first set read off the task documents themselves, the second off a `task-audit` run earlier in this conversation (or dated audit notes embedded in the documents). Both sets always override bucket-shape moves; the rubric's Action column is written in this skill's bucket vocabulary and applies here literally.

Then assess the **focus** the Phase 1 read produced, and compute its **workability**: of
the in-focus tasks, how many are not `blocked`. That count is the signal the whole
weighting is built to preserve — see below.

Print a diagnosis block:

```
Current shape: now=N, soon=N, later=N (finalized=N ready; queued=N executing)
Targets:       now≈3, soon≈3, later=rest

Focus: <present, last touched YYYY-MM-DD | present but >30 days old (YYYY-MM-DD) — using it anyway, does it still hold? | present but never committed — staleness unknown | ABSENT — this pass ranked on mechanics alone>
- statement: <one-line paraphrase of the prose>
- not now: <the **Not now:** line, or "none">
- in focus (K of M tasks): <task> ("<quoted fragment>"), ...
- workable: <J of K in-focus tasks can be started (K-J blocked)>

Bucket health:
- now: <under-target by K | at-target | over-target by K>
- soon: <under-target by K | at-target | over-target by K>

Readiness/evidence overrides detected:
- <task>: <override action> (<reason>)
...

Queued context (read-only):
- <task> [area:<area>]

Finalized context (read-only):
- <task> [area:<area>]
...
```

**When every in-focus task is blocked, say so loudly**, on its own line, before the plan:

```
!! The stated focus is currently entirely unworkable: all K in-focus tasks are blocked.
   Rebalancing cannot fix this — it reports it. Unblocking one of them, or rewriting
   <tasks>/focus.md, is the real next move.
```

That report is not decoration. Reading a focus statement makes it tempting to promote
work merely because it sits in the named area, and a queue that looks aligned while
nothing in it can be started is strictly worse than one that says so. Focus never
promotes blocked work into `now/` (rubric § How much focus weighs); this line is what
the reader gets instead.

With **no focus document**, print the `Focus: ABSENT` line above and omit the four
sub-lines — never omit the block. The rest of the pass runs on mechanics exactly as it
always did.

If shape is at-target AND no overrides apply, print "Queue is at-target — no moves." and stop.

---

## Phase 3 — Build the Rebalance Plan

This is the heart of the skill. Build **one** plan that satisfies hard rules, classifies each candidate by where it fits naturally, then places them into target buckets. Apply it as a single batch in Phase 4.

### Plan-building order

Apply these steps in order. After each step, recompute bucket counts so the next step sees the updated state.

#### Step 1 — Hard overrides

For each readiness or evidence signal from Phase 2:

- **All acceptance criteria checked in any bucket, or audit-confirmed complete** → schedule a deletion. Rationale: "all criteria met; flag for removal" (cite audit evidence where available). This takes precedence over every other readiness action.
- **Blocked in `now/`** → schedule a demote to `soon/`. Rationale: "status=blocked; revisit when unblocked". **Focus does not change this demotion** — an in-focus blocked task still leaves `now/`. What it changes is what happens next: mark an in-focus one **trim-protected**, and Step 5 will not push it on to `later/` (rubric § How much focus weighs). Note the protection in the rationale, with the citation. A blocked task outside `now/` is never promoted because of progress or in-flight status.
- After those completion and blocked-state actions, **recompute `now/`**. If it is below its target of three, rank every remaining task outside `now/` with `status: in-progress` or any checked acceptance criterion by higher progress fraction, explicit priority (`high`, then neutral `medium`, then `low`), older creation time, smaller effort, then task slug alphabetical. Promote only enough eligible tasks to fill the open slots. Rationale: "in-flight promotion (X/Y criteria done)"; name explicit priority whenever it changed which task received a slot. Eligible tasks that do not fit remain where they are and retain Step 2's anti-demotion protection.
- **Audit-backed promotion** (blocking work, landed dependency, invalidated parking rationale, velocity work) → schedule the promotion, citing the evidence.

These overrides override shape concerns, and focus does not outrank any of them. They run first so the rest of the plan sees the corrected state.

#### Step 2 — Classify each candidate by placement category

For each task currently in `now/`, `soon/`, or `later/` *not* claimed by a Step 1 override, assign a **placement category** per [`ranking-rubric.md` § Placement categories](ranking-rubric.md#placement-categories-n--s--l) — **N** (single-area production work) → `now/`, **S** (multi-area production, or support-only work) → `soon/`, **L** (foundational system change) → `later/`, defaulting to **S** with "(category ambiguous; defaulted to S)" when no rule fits cleanly.

**Focus plays no part in this step.** Categories are decided by `## Scope` alone; focus reorders tasks *within* a category in Step 3, and never moves one between categories. An in-focus foundational rewrite is still **L**.

Before categorizing, apply [`ranking-rubric.md` § In-flight pinning](ranking-rubric.md#in-flight-pinning): a remaining eligible in-flight task stays in its current bucket only as an **anti-demotion floor** — category and shape may not push it down, but Step 1 may have promoted it. Note these as "pinned (in-flight; anti-demotion)" in the plan output. They still consume a slot toward the bucket's target count.

#### Step 3 — Sub-rank within each category by focus, area-coupling, and tiebreakers

Order the tasks in each category in this sequence:

1. **Focus** (rubric § How much focus weighs) — in-focus above out-of-focus, and below both, anything the `**Not now:**` line names. This runs *first*, ahead of the coupling tiers: it is the strongest thing focus does to ordinary ranking.
2. **Area-coupling tier** — [`ranking-rubric.md` § Area-coupling tiers](ranking-rubric.md#area-coupling-tiers-a--b--c): **A** (shares an area with a `queued/` task), **B** (distinct from every queued area), **C** (shares an area with an `in-progress` task already in `now/`). In repos without a queue, every task is Tier B unless it matches an `in-progress` task in `now/`.
3. **Tiebreakers** — [`ranking-rubric.md` § Tiebreakers](ranking-rubric.md#tiebreakers): higher progress fraction, explicit `high` / neutral `medium` / `low` priority, older creation date, smaller `effort`, then task slug alphabetical. Name a placement where explicit priority changed the result.

With no focus document, step 1 is a no-op and the order is the coupling tier then the tiebreakers, exactly as before.

#### Step 4 — Place into target buckets

Before every placement, recompute the receiving bucket's count.

- Fill `now/` from ranked N candidates up to three, recomputing the receiving count for every placement. A surplus N task may overflow to `soon/` only when adding it would not exceed `soon/`'s tolerance ceiling of four; later surplus falls to `later/`.
- Fill `soon/` from ranked S candidates up to its target of three, counting every task already placed there — pinned tasks, Step 1 demotions, and N overflow. Surplus S tasks fall to `later/`.
- All L candidates → `later/`.

If `now/` is under-target after N exhausted (e.g. only 2 N tasks exist), pull the top S candidates to backfill — prefer **in-focus** S candidates first, then those whose area doesn't already match a now-placed task. Note these as "(promoted from S — N pool short)" in the rationale, with the focus citation where focus decided which one.

If `soon/` is under-target after S exhausted, leave it under-target rather than dragging up infrastructure. Note the deviation: "soon/ under-target by K; only infra candidates remain."

#### Step 5 — Trim over-target buckets

If after Step 4 either bucket exceeds target + 1 (tolerance), demote bottom-ranked tasks from that bucket to the next bucket down. Bottom-ranked = out-of-focus before in-focus, then lowest coupling tier within category, then lowest progress, then lowest explicit priority, then largest effort, then task slug alphabetical as the stable final fallback. **Age is not a trim term.** Placement uses older-first because waiting is meaningful there; using that order for trimming would make the newest task lose. Do not demote a task that was just promoted in this same plan run (avoid promote-then-demote churn).

Three tasks are **not eligible** as trim victims:

- Anything pinned in-flight by the anti-demotion floor (rubric § In-flight pinning) — as before.
- A **blocked in-focus** task that Step 1 demoted into `soon/`, which Step 1 marked trim-protected. "Revisit when unblocked" only works if the task stays where it will be looked at.
- A task whose **first commit is within 7 days** (at most seven 24-hour periods at run time), or that has **no creation commit** yet. A missing commit stays epoch-old for ordinary placement, but trimming treats it as fresh because a newly filed working-tree task has no history either.

If the protections leave a bucket over tolerance, **stop trimming and name the deviation** rather than trimming something protected: "soon/ over tolerance by K — J blocked in-focus tasks are trim-protected there." That is the same shape as the in-flight-pinning deviation the skill already reports, and it is the honest reading — the shape target did not flex, the queue is genuinely carrying more deferred in-focus work than the shape wants, and that is worth seeing.

### Edge cases

- **Total task count too small**: e.g. only 4 tasks across now+soon+later. Use proportional targets: 2 in `now/`, 2 in `soon/`, 0 in `later/`. State the deviation explicitly: "Total tasks=4; treating target as now=2/soon=2."
- **Many tasks in `queued/`**: when `queued/` has ≥3 tasks (the autonomous worker is well-fed), it's fine to leave `now/` slightly under-target (2 instead of 3). Note this deviation explicitly.
- **No creation commit** (file never committed): the rubric's ordinary-placement tiebreaker treats it as oldest, while Step 5 protects it from trimming as fresh.
- **Area inference fell back to title**: include "(area inferred from title)" in the rationale so the user can correct.
- **Task already in the right bucket per its category**: no move needed. Don't churn for no-op reassignments.
- **No `focus.md`**: rank on mechanics alone, and say so in the diagnosis block's `Focus: ABSENT` line and again in the final report. Never let a mechanics-only pass read as a focus-honouring one — that is the failure the rubric's Staleness branch exists to prevent.
- **`focus.md` older than ~30 days**: use it anyway and flag the age, asking in the output whether it still holds. A stale statement of intent still beats no statement.
- **`focus.md` exists but was never committed** (`git log -1` prints nothing and exits 0): use it, and report "staleness unknown — not committed yet". Never read empty output as fresh.
- **A focus rewrite moved several un-started tasks**: expected, not a bug (rubric § Churn). Say how many moves focus drove, so the effect is visible rather than inferred.

---

## Phase 4 — Apply the Plan

Print the full plan as a table **before** any move:

```
### Proposed rebalance plan (N moves)

| # | Task | From | To | Cat | Coupling | Focus | Rationale |
|---|------|------|----|-----|----------|-------|-----------|
| 1 | harden-importer-retry-backoff | soon/ | now/ | — | B | "The importer and the record model it feeds" | in-flight promotion (2/5 criteria done); open `now/` slot |
| 2 | unify-the-two-model-construction-paths | later/ | now/ | N | B | "how records are constructed" | single production area; fills the remaining N slot |
| 3 | replace-hand-rolled-schema-updates-with-migrations | soon/ | later/ | L | B | **Not now** | introduces a migration framework + startup change — infra rewrite |
| 4 | swap-the-report-renderer | now/ | soon/ | — | B | — | status=blocked; revisit when unblocked |
| ...                                  | ...   | ...  | ... | ... | ... | ... |
```

(`Cat` = placement category N/S/L from Step 2. `Coupling` = area-coupling tier A/B/C from Step 3.)

The **`Focus` column is what makes a focus-driven move legible without re-deriving the ranking**, so fill it honestly, per move:

| Cell | Means |
|---|---|
| `"<quoted fragment>"` | In focus — this is the sentence that covers the task (rubric § What counts as in focus) |
| `**Not now**` | Named by the `**Not now:**` line — actively lowered |
| `—` | Out of focus. Neutral: the move was decided on mechanics alone |
| `— (no focus doc)` | There is no `focus.md`; the whole pass was mechanics-only |

A quoted fragment in this column is a claim that focus *contributed* to the move. Where focus was read but changed nothing about a particular move, the citation still belongs there — it says the task is in focus and the mechanics agreed anyway — but the Rationale must not credit focus for a decision the mechanics made on their own. After the table, state in one line how many moves focus actually decided, and name them.

For each move, run:

```bash
git mv <tasks>/<source>/<task>.md <tasks>/<target>/<task>.md
```

For each deletion, run:

```bash
git rm <tasks>/<bucket>/<task>.md
```

Apply all moves directly. **Do not call a question prompt.** If the user disagrees with the plan they can `git checkout` the staged changes — that's cheaper than a per-move round-trip.

If the plan is empty (shape is at-target and no overrides apply), print "Queue is at-target — no moves applied." and stop.

After applying, print:

```
Done. Final shape: now=N, soon=N, later=N.
Focus: <how it was read, and how many of the N moves it decided | "ABSENT — ranked on mechanics alone">
Review the staged moves: `git status` then `git diff --staged --stat`.
Do **NOT** auto-commit. Commit when satisfied.
```

Carry any deviation Step 4 or Step 5 named into this block too — an under-target `soon/`, a bucket held over tolerance by trim-protected in-focus tasks, or a focus that is entirely unworkable. A deviation reported only inside the plan-building narrative is a deviation the reader skims past.

---

## Worked example

A synthetic queue that exercises every branch of the algorithm — an at-a-glance regression check when modifying this skill. The paths belong to an invented web app; the mechanics are repo-agnostic.

**The focus document** (`<tasks>/focus.md`, last committed 6 days ago — current):

```markdown
# Focus

The importer and the record model it feeds: getting imported records into one
normalized shape before anything else is built on top of them. Work counts as in
focus when it changes how records are constructed, typed, or loaded from fixtures,
or when it unblocks that path.

**Not now:** replacing foundational plumbing — the migration framework in particular — until the record shape has stopped moving.
```

**Inventory:**

| Bucket | Task | Status | Effort | Progress | Area | Focus |
|---|---|---|---|---|---|---|
| `now/` | `backfill-importer-provenance-columns` | blocked | medium | 0/4 | importer | "how records are constructed" |
| `now/` | `link-records-to-their-source-batch` | blocked | medium | 0/3 | importer | "how records are constructed" |
| `now/` | `dedupe-records-across-import-batches` | blocked | large | 0/6 | importer | "one normalized shape" |
| `now/` | `swap-the-report-renderer` | blocked | medium | 0/5 | reports | — |
| `now/` | `normalize-imported-record-fixtures` | not-started | small | 0/3 | fixtures | "loaded from fixtures" |
| `soon/` | `harden-importer-retry-backoff` | in-progress | medium | 2/5 | importer | "The importer and the record model it feeds" |
| `soon/` | `replace-hand-rolled-schema-updates-with-migrations` | not-started | large | 0/7 | models | **Not now** |
| `later/` | `unify-the-two-model-construction-paths` | not-started | medium | 0/4 | importer | "how records are constructed" |
| `later/` | `introduce-record-id-newtype` | not-started | medium | 0/5 | (multi) | "constructed, typed, or loaded" |
| `later/` | `type-session-json-columns-against-schema-models` | not-started | large | 0/6 | (multi) | "constructed, typed, or loaded" |
| `later/` | `refactor-simulator-test-architecture` | not-started | medium | 0/4 | tests:evals | — |

`queued/` (read-only): `rebaseline-parser-fixtures-after-tokenizer-fix` (parser), `rework-task-reprioritize-skill` (skills), `tune-billing-proration-for-mid-cycle-upgrades` (billing).

**Diagnosis:**

- now=5 → over-target by 1 (tolerance ceiling is 4); soon=2 → under-target by 1; later=4
- Focus present, last touched 6 days ago — current. In focus: 8 of 11. **Workable: 5 of 8** (`backfill`, `link-records`, `dedupe` are blocked) → the focus is workable, so no "entirely unworkable" report; the count is still printed.
- Readiness overrides: four tasks blocked in `now/`.
- Queued areas: parser, skills, billing. No candidate shares them — every candidate is Tier B.

**Step 1 — Hard overrides:** all four blocked `now/` tasks demote to `soon/`. Three are in focus → **trim-protected**; `swap-the-report-renderer` is not. Recomputed: now=1, soon=6. `harden-importer-retry-backoff` is the only eligible in-flight task outside `now/`, so its 2/5 progress fills one of the two open slots: now=2, soon=5. No complete or blocked task can enter that promotion pool.

**Step 2 — Classify** the tasks Step 1 did not claim. The remaining normal candidates are categorized below; any eligible in-flight candidate that did not fit in Step 1 would remain in its current bucket under the anti-demotion floor.

| Task | Scope areas | Category | Rationale |
|------|------|---|---|
| `normalize-imported-record-fixtures` | `app/fixtures/imported_records/` | **N** | single production area |
| `unify-the-two-model-construction-paths` | `app/features/importer/...` (single area) | **N** | single production area |
| `introduce-record-id-newtype` | `app/features/search/`, `app/features/reports/`, `app/features/editor/`, `app/api/` | **S** | multi-area production work |
| `type-session-json-columns-against-schema-models` | `app/models/`, `app/features/search/`, `app/features/importer/`, `app/features/schema/`, `app/api/` | **S** | multi-area production work |
| `refactor-simulator-test-architecture` | `tests/unit/evals/simulator/` only ("No production changes required") | **S** | test-only |
| `replace-hand-rolled-schema-updates-with-migrations` | `app/models/database.py`, new `migrations/` dir, `app/main.py`, docs | **L** | introduces a migration framework + startup change |

Note `replace-hand-rolled-schema-updates-with-migrations`: the `**Not now:**` line names it, but it was already **L**. Focus **confirmed** its placement rather than causing it — do not credit focus in its Rationale.

**Step 3 — Sub-rank** (focus → coupling tier → tiebreakers; all Tier B, none has progress, and all have neutral `medium` priority, so the tiebreakers reduce to age → effort → slug):

- **N**: `normalize-imported-record-fixtures`, `unify-the-two-model-construction-paths` — both in focus, so focus does not separate them; age decides (`normalize` is older).
- **S**: `introduce-record-id-newtype`, `type-session-json-columns` (both in focus) rank above `refactor-simulator-test-architecture` (out of focus). Without focus, `refactor-simulator` would have outranked `type-session-json-columns` on smaller effort.
- **L**: `replace-hand-rolled-schema-updates-with-migrations`.

**Step 4 — Place:**

- `normalize-imported-record-fixtures` is already in `now/`, and Step 1's promotion leaves exactly one N slot open. `unify-the-two-model-construction-paths` fills it: `now/` ← `normalize-imported-record-fixtures`, `harden-importer-retry-backoff`, `unify-the-two-model-construction-paths` → now=3 ✓. No S backfill occurs.
- `replace-hand-rolled-schema-updates-with-migrations` is **L** → `later/`. `soon/` now holds four tasks: `backfill`, `link-records`, `dedupe` (all three protected), and `swap-the-report-renderer`.
- Because `soon/` already has four tasks — its tolerance ceiling — every S candidate falls to `later/`: `introduce-record-id-newtype`, `type-session-json-columns`, `refactor-simulator-test-architecture`.

**Step 5 — Trim:** `soon/`=4 is at, not beyond, the tolerance ceiling, so no trim occurs. `swap-the-report-renderer` remains in `soon/`.

**Focus decided no moves in this example.** It still changes the S ordering and records trim protection for the three blocked in-focus tasks, but the count-aware placements leave `soon/` at its ceiling without a trim. The plan's closing line therefore reports zero focus-decided moves rather than attributing the old `swap-the-report-renderer` demotion to focus.

**Final shape:** now=3, soon=4, later=4. `harden-importer-retry-backoff` is in `now/`; `swap-the-report-renderer` remains in `soon/`.

**Edge-case regression checks:**

| Case | Expected plan result |
|---|---|
| Blocked task with partial progress | Demote it from `now/` or leave it outside `now/`; never promote it for progress or in-flight status. |
| All-complete task outside `now/` | Flag it for deletion before category or promotion logic. |
| More eligible in-flight tasks than open `now/` slots | Promote only the open-slot count, ordered by progress, explicit priority, age, effort, then task slug; leave the rest anti-demotion protected. |
| Fresh trim candidates | A task whose first commit is within seven days and a task with no creation commit are both trim-protected. |
| N overflow at the `soon/` ceiling | One surplus N task may fill a fourth `soon/` slot; a further surplus falls to `later/`. |

---

## Notes

- This skill replaces the older per-symptom heuristic that proposed one move at a time behind a question-prompt round-trip. The single-pass, decide-then-apply design is intentional (and a recorded user preference): if the queue is misshapen by 3, the user should not have to answer 3 prompts — the plan is printed before moves so they can `git checkout` if they disagree.
- Frontmatter `dependencies:` is execution-order data (in queue repos, a dependent is never claimed before its dependency merges). This skill reads it as context but still infers *area* coupling from Scope paths.
