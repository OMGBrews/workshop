# Task ranking rubric

How to rank task documents against one another: area inference, in-flight pinning,
readiness and evidence signals, placement categories, area-coupling tiers, and
tiebreakers. Read this from `/task-reprioritize`, which ranks in order to shape
buckets. Nothing in this document moves a file or edits one; the skill decides what
to do with the ranking it produces.

**`/task-next` deliberately does not read this document** (decoupled 2026-08-11; it
did before). The selector is a latency-bound quick pointer that ranks on a five-signal
subset stated inline in its own SKILL.md, and it is allowed to diverge from this
rubric: close enough is good enough at selection time, because a bad pick costs the
user seconds, while a bad *placement* persists in the queue's structure until the next
rebalance. The two skills stay aligned through the buckets themselves — this rubric's
judgment is written into placement, and the selector trusts placement (first non-empty
bucket) instead of re-deriving it. Selection therefore degrades gracefully, not
identically, when a rebalance is overdue.

The file lives inside the `task-reprioritize` skill because that is where the rules
were written and proven, following the `_TEMPLATE.md` precedent (a canonical file
inside one skill, referenced across skill boundaries).

---

## Area inference

Read the `## Scope` section and reduce each mentioned path to a coarse **area label**:

1. If `<tasks>/README.md` contains an **"Area map"** section (a repo-specific path-pattern → area table), use it — first matching pattern wins.
2. Otherwise, derive the label mechanically: strip the filename, take the first directory component of the path — and when that component is a generic container (`app`, `src`, `lib`, `packages`, `Assets`, `tests`, `docs`, `evals`, `features`), append the second component: `app/features/search/…` → `app/features` is still generic, so keep descending until the component is specific — `feature:search`-style granularity, i.e. the deepest component that names a subsystem rather than a container. Examples: `app/features/search/ranking.py` → `search`; `tests/unit/evals/` → `tests:evals`; `docs/planning/` → `docs`; `Assets/Scripts/Player/` → `Player`.

If a Scope section lists paths from **multiple** areas (common for cross-feature refactors), record all of them in order of frequency; the **primary area** is the first/most-mentioned.

If `## Scope` is missing or empty, derive the primary area from the title (e.g. `search` → the search feature, `eval` → evals, `test` → tests). Note this fallback explicitly in the rationale you print, so the user can correct it.

---

## In-flight pinning

**In-flight pinning is a floor, not a freeze**: a task with any checked acceptance
criteria (`- [x]`) or `status: in-progress` is protected from a category- or
shape-driven **demotion**, not from a readiness-driven promotion. The protection applies
only while the task is neither blocked nor complete: blocked and complete precedence
comes first. Note protected tasks as "pinned (in-flight; anti-demotion)" in the plan
output. They still consume a slot toward the bucket's target count.

(`/task-next` states the same intuition inline as its first ranking rule — resume
beats start — without reading it from here.)

---

## Readiness and evidence signals

These always override ordinary ranking.

> **`Created` in the tables below is derived, not stored.** Task documents carry **no
> `Created:` field** — it was removed fleet-wide in the 2026-07-26 format convergence,
> and "no dates in docs, tasks included" is a workspace rule. Read it from the file's
> first commit:
>
> ```bash
> git log --diff-filter=A --follow --format=%aI -- <task-file>
> ```
>
> `%aI` (author date, full ISO) is deliberate: it keeps sub-day
> resolution, so two tasks created the same day still tiebreak deterministically.
> `--follow` is what makes the date survive the `git mv` between buckets. Shorten for
> display if you like; compare on the full value.
>
> The 14-day threshold still measures what it always measured: the 2026-07-26
> convergence *modified* existing task files rather than recreating them, so
> `--diff-filter=A` dates were not rewritten. Verified against hq's queue — e.g.
> `tier2-non-cms-python-local-ci.md` reports first-commit `2026-06-09` with a last
> modification of `2026-07-30`.

| Signal | Action |
|---|---|
| All acceptance criteria checked, in any bucket | Flag for deletion (work appears complete) before every other readiness action |
| Task with status `blocked` | Exclude from every progress- or in-flight-based promotion; when it is in `now/`, demote it to `soon/` with note "blocked — revisit when unblocked" |
| Every other task outside `now/` with status `in-progress` or any checked acceptance criterion | Eligible for an in-flight promotion to an open `now/` slot; rank eligible tasks by the tiebreakers and promote only enough to reach the target |
| Task in `now/` with status `not-started` and Created > 14 days ago | Tag as "stale `now/`"; don't auto-demote but call it out for the user |

And **evidence-based signals**, when a `/task-audit` run earlier in this conversation reported reprioritization signals (or dated audit notes are embedded in the documents):

| Signal | Action |
|---|---|
| Audit found all acceptance criteria met | Flag for deletion, citing the audit evidence |
| Core problem mostly solved | Demote (or flag for deletion), citing the evidence |
| Task blocks higher-priority work, or a listed dependency has landed | Promote to at least the blocked work's bucket |
| Documented parking/deferral rationale no longer holds | Promote for re-evaluation |
| Velocity work (developer experience, tooling, kaizen) | Place **at least in `soon/`, often `now/`** — accelerating development usually beats completing individual fixes or features |


---

## Placement categories (N / S / L)

These categories encode the ranking intuition: narrow production tasks ship sooner; broad-or-support tasks queue behind them; infrastructure rewrites stay parked.

Read the `## Scope` section and apply the first matching rule. **"Production code"** means the repo's primary deliverable tree — whatever ships (`app/`, `src/`, a Unity project's `Assets/`, a library's package directory); **"support work"** means tests, evals, docs, scripts, and tooling around it.

| Category | Rule | Goes to |
|----|------|----|
| **N** (now-ready) | Scope touches production code **AND** the inferred primary areas reduce to one. Single-area production work, focused enough to start immediately. | `now/` |
| **S** (soon-ready) | Scope touches production code **with multiple primary areas** (cross-feature refactor, typing project, API+model change), **OR** Scope is exclusively support work (test-only, eval-only, docs-only). Production-broad or support work — valuable but a tier behind narrow production. | `soon/` |
| **L** (later-ready) | Scope adds or replaces a foundational system (a migration framework, build/deploy plumbing, startup orchestration, engine/framework version moves). Heuristic flags: new top-level directories combined with changes to the app's entry point, wholesale removal of foundational modules, mentions of `migrations/`-style scaffolding. Highest blast radius — these get planned, not picked up casually. | `later/` |

If a task doesn't fit any rule cleanly, default to **S** and note "(category ambiguous; defaulted to S)" in its rationale.

---

## Area-coupling tiers (A / B / C)

Within each category, order tasks by **area-coupling tier**. In repos without a queue, every task is Tier B unless it matches an `in-progress` task in `now/` (Tier C).

| Tier | Definition | Notes |
|---|---|---|
| **A** | Primary area matches a `queued/` task's area, OR the task explicitly references a queued task by filename | Promoting this primes follow-up work in the same area the autonomous worker is touching. |
| **B** | Primary area is distinct from every `queued/` task's area | Safe complement — no contention with in-flight work. |
| **C** | Primary area matches an `in-progress` task already in `now/` | Avoid clumping competing tasks in the same area. Last resort. |

---

## Tiebreakers

Within each tier, prefer (in order):
1. Higher progress fraction (in-flight > not-started — already underway).
2. **explicit priority**: `high`, then neutral `medium`, then `low`. `medium` is neutral
   because it is the template default; `high` and `low` are deliberate signals, but
   remain weaker than progress.
3. Older Created date first (waited longer).
4. Smaller `effort` first (`small` before `medium` before `large`).
5. Task slug alphabetical as the stable final fallback.

`Created` is derived from the file's first commit — see the definition under
[Readiness and evidence signals](#readiness-and-evidence-signals); do not look for a
frontmatter field, there is none.

**No git creation date** (file never committed): treat the task as oldest (created at epoch) — this avoids penalizing tasks for missing metadata.

---

## Focus weighting (`<tasks>/focus.md`)

A repo may state, in its owner's own words, what matters right now. That statement
lives at `<tasks>/focus.md` — the tasks root, beside `README.md`, deliberately outside
every bucket directory so no task glob mistakes it for a task.

[`docs/focus-document.md`](../../../docs/focus-document.md) is the single specification
for the artifact's format, authoring contract, parsing rules, and exclusions. This
section owns only the reader-side weighting and staleness mechanics applied by
`/task-reprioritize`.

`/task-reprioritize` reads it at each rebalance — **coarse and durable** — to decide
which bucket a task sits in, so the queue's shape carries the stated direction between
rebalances. (`/task-next` also reads the *file*, live at each selection, but by its own
lighter rule — see its SKILL.md, not this section. The two reads are not
double-counting: placement writes the direction into a structure that persists
unattended, and where the two disagree the fresher selection-time read wins.)

- **No skill writes a next task into it.** `/session-land` records a session's resume
  point in the task document the work belongs to, not here; `/task-next` then surfaces
  it through in-flight pinning. See [Direction, not a next task](../../../docs/focus-document.md#direction-not-a-next-task).

### What counts as in focus

This is `/task-reprioritize`'s rule. (`/task-next` applies a looser judgment at
selection time — deliberately: a wrong lift there costs seconds, while a wrong lift
here persists in the queue's structure until the next rebalance, so placement is where
the evidence requirement earns its cost.)

A task is **in focus** when a **specific quotable sentence** of the focus prose covers
its **In brief**, `## Goal`, or `## Scope`. That is a semantic judgment made by reading
both documents — not a path match, not a label match — and the judgment carries its
evidence: the quoted fragment travels with it into the plan table, so a reader can see
*which sentence* fired.

Requiring the quote is what makes the rule work on real focus documents, which routinely
state conditions rather than areas. A focus saying that work elsewhere counts "exactly
when it unblocks this path" cannot be matched by extracting directory names from it; it
can be matched by reading a task and pointing at that clause. The requirement is also the
guard: if you cannot quote a sentence that covers the task, it is not in focus, however
plausible the association felt.

- **No citable sentence → out of focus, which is neutral.** Out of focus is the ordinary
  state of most of a queue. It carries no penalty — the task ranks on mechanics alone.
- **The `**Not now:**` line actively lowers** the tasks it names. That single line is the
  only part of the document that pushes down rather than merely failing to lift.

### How much focus weighs

**Focus modifies the mechanics; it never overrides them.** Every rule that already
decides an outcome keeps its full force — [Readiness and evidence
signals](#readiness-and-evidence-signals) and [In-flight
pinning](#in-flight-pinning). Focus never overturns the blocked-in-`now/` demotion or
the in-flight anti-demotion floor.

What it does, in each place a ranking is formed:

- **Ordering within a placement category.** In-focus ranks above out-of-focus, applied
  *before* the coupling tiers and tiebreakers. Focus reorders the pool; it never moves a
  task between the N/S/L categories, which are decided by Scope alone.
- **Backfill preference.** Where `now/` is under-target and S candidates are pulled up,
  prefer in-focus ones, then area diversity.
- **Trim preference.** Where a bucket is over tolerance, trim out-of-focus tasks first.
- **The trim exemption.** A **blocked in-focus** task demoted out of `now/` lands in
  `soon/` and is **exempt from the onward trim to `later/`**. "Blocked — revisit when
  unblocked" is only useful if the task stays somewhere it will be looked at, and the
  focus statement is the evidence that it will be. Where the exemption leaves `soon/`
  over tolerance, report the deviation by name, exactly as in-flight pinning already
  does.

That exemption is the whole of focus's extra reach into placement, and it is deliberately
this small: **the shape targets themselves do not flex.** Focus decides which tasks fill
the shape, never how big the shape is.

**Say so when the focus is unworkable.** If every in-focus task is blocked, that is a
finding and it must be reported in as many words: the
stated focus is currently unworkable. Do not paper over it by promoting blocked work on
the strength of its area. A queue that honestly reports "the thing you said matters
cannot be started" is more useful than one that merely looks aligned, and losing that
signal is the sharpest cost this weighting could carry.

### Churn

A rewritten focus is expected to move a handful of un-started tasks at the next
rebalance. That is the feature operating, not noise — buckets that track declared intent
have to move when the intent changes. The existing dampers bound it: the in-flight
anti-demotion floor keeps started work from being pushed down, no-op reassignments are
suppressed, a task promoted in a run is not demoted again in the same run, and the
weight-not-override design above keeps focus away from anything the mechanics have an
opinion about.

No hysteresis rule, deliberately. A damper for observed flapping can be added when
flapping is observed; adding one now would be tuning against a problem nobody has
measured.

### Staleness

**Test that the file exists first, and only then ask git how old it is.** Absence is not
one of this command's output branches:

```bash
git log -1 --format=%cs -- <tasks>/focus.md
```

`git log` reports the last commit that *touched* a path, so for a focus document someone
deleted it exits 0 and prints an ordinary recent date (measured). A reader that skips the
existence test therefore gets a confident "focus is current" for a file that is not
there — the pass state reached by the very failure the check exists to detect. Stat the
file; then branch on the command's output:

- Date older than roughly 30 days → say so, ask whether the focus still holds, and
  **use it anyway**. A stale statement of intent still beats no statement.
- **Empty output is not a date.** That command exits 0 and prints nothing when the file
  exists but has never been committed. Treat empty as "not yet committed — staleness
  unknown" and say that; never let it read as fresh.
- File absent → say so out loud and rank on mechanics alone. Silent degradation is the
  failure mode to avoid: the user must never mistake a mechanics-only ranking for one
  that honored a focus they thought was being read.

**Branch on all four cases, and name the branch taken.** For `/task-reprioritize` this
shapes an entire pass: an absent focus means the whole rebalance ran on mechanics, and
the report has to say that where the focus findings would otherwise have gone — or the
queue silently stops honouring a document the owner still believes is being read.
(`/task-next` carries its own copy of these branches inline, for the same reason.)

---

## See also

- [`SKILL.md`](SKILL.md) — `/task-reprioritize`, which applies this rubric to bucket placement (and carries the worked example that pins the rubric's behavior)
- [`docs/focus-document.md`](../../../docs/focus-document.md) — the single focus-document specification shared by writers and readers
- [`../task-next/SKILL.md`](../task-next/SKILL.md) — `/task-next`, the fast selector that deliberately does *not* read this rubric; it trusts the bucket placement this rubric produces
- [`../task-create/_TEMPLATE.md`](../task-create/_TEMPLATE.md) — the canonical task template, the precedent for a shared file living inside one skill
