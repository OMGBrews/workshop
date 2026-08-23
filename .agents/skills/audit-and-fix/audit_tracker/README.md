# audit_tracker

Tracks which files and directories in **your** repo have been audited, when,
and against which commit — so you can ask "what should I audit next?" for each
audit type. This is the engine behind the [`audit-and-fix`
skill](../README.md); read that first for consumer onboarding and the opt-in
config.

> **About to merge a branch?** Audit records are stored as text in
> `docs/work/audits/records/<type>.json` so concurrent branches merge cleanly.
> See [Merging audit records](#merging-audit-records) below for the
> conflict-resolution playbook.

## Model

- **Audit types** are declared in the *consumer* repo's
  `docs/work/audits/config.toml` — its existence is the tracker's opt-in. Each
  type has `targets`: a list of `{kind, include, exclude}` rules. `kind` is
  `file` or `directory`. Includes/excludes are gitignore-style globs (`**`
  spans whole segments and needs at least one).
- **Paths** are every tracked file (from `git ls-files`) plus every parent
  directory, regardless of audit type — **except paths owned by a submodule
  and all tracked symlinks**, which are dropped before anything else runs. Git
  history for a symlink follows the link blob rather than changes to the target
  an auditor reads, so even an in-repo link would produce misleading staleness.
  A link into a submodule is worse: fixes land in the submodule's working tree,
  go unstaged by an ordinary `git add` here, and can be overwritten by the next
  upstream publish. `git_utils.submodule_owned_paths()` resolves tracked links
  fully (including chains through directory symlinks) and drops anything
  landing inside a gitlink root, along with the roots themselves.
- **Applicability** is a per-type filter: a `(path, audit_type)` row exists
  iff the path matches one of the type's rules — **except that empty files are
  withheld from every type**. Auditing a zero-byte file can only ever conclude
  "it is empty", and repos full of empty `__init__.py` package markers
  otherwise queue them once per applicable type. `git_utils.empty_blob_paths()`
  reads emptiness out of the index (`git ls-files --stage` reports git's
  zero-length blob SHA) rather than matching on filename: a *non-empty*
  `__init__.py` is legitimately audit-worthy. Two deliberate asymmetries vs.
  the submodule rule: this filter drops rows from applicability rather than
  from `paths`, so audits already recorded against an empty path keep loading
  instead of being reported as orphans "no longer in git"; and it runs *after*
  directory derivation, so a directory whose only tracked file is an empty
  marker still appears in the directory-kind pools.
- **Audits** are one row per `(path, audit_type)` — the last time you audited
  that path for that type, at which commit, with an optional note.

Staleness is computed on the fly from Git. Paths sharing an audit commit are
classified by one `git log --name-only` history walk rather than two Git
processes per path. Exact results are cached under the current HEAD in the
derived SQLite database, so repeated `status` and `next --stale` calls do not
walk history again. A directory audit is stale if any file below it changed.

## CLI

Run from your repo root. The canonical spelling goes through the skill's
launcher (which pins the Python floor and keeps bytecode out of the mount):

```bash
# Reconcile paths + applicability with the current git tree and config
python3 .agents/skills/audit-and-fix/tracker.py refresh

# What should I audit next?
python3 .agents/skills/audit-and-fix/tracker.py next code-quality
python3 .agents/skills/audit-and-fix/tracker.py next doc-quality -n 5
python3 .agents/skills/audit-and-fix/tracker.py next readme-quality --never

# Stable machine output: selected/empty/not-configured are distinct outcomes
python3 .agents/skills/audit-and-fix/tracker.py next code-quality --format json

# Restrict to files or directories only
python3 .agents/skills/audit-and-fix/tracker.py next code-quality --kind file

# Scope to a subtree (the path itself plus its descendants)
python3 .agents/skills/audit-and-fix/tracker.py next code-quality --under app/features/suggestions

# Summary / inventory
python3 .agents/skills/audit-and-fix/tracker.py status code-quality
python3 .agents/skills/audit-and-fix/tracker.py list-types

# Canonicalize and prove an explicit path is tracked, owned, and applicable
python3 .agents/skills/audit-and-fix/tracker.py validate-path ./app/features code-quality
python3 .agents/skills/audit-and-fix/tracker.py validate-path /absolute/path/in/repo code-quality --format json

# Mark something as audited (records current HEAD)
python3 .agents/skills/audit-and-fix/tracker.py done app/features/suggestions/engine.py code-quality
python3 .agents/skills/audit-and-fix/tracker.py done docs/architecture doc-quality --note "swept structure"
```

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | success (including `empty` and JSON `not-configured` outcomes) |
| 1 | `done` refused: path not applicable for that type |
| 2 | bad arguments, or config missing on disk but explicitly passed / invalid |
| 4 | **not opted in** in legacy text mode. JSON `next` reports `{"outcome":"not-configured"}` with exit 0; `validate-path` remains available without config. |

### Filters on `next`

- `--never` — only never-audited paths. Mutually exclusive with `--stale`.
- `--stale` — only paths with commits since their last audit (matches the
  `stale=N` column in `status` output). Mutually exclusive with `--never`.
- `--kind file|directory` — restrict to one kind.
- `--under <path>` — restrict to a subtree. Must be repo-relative; leading
  `./` and trailing `/` are stripped, and absolute paths or `..` segments are
  rejected.
- `-n / --limit` — number of candidates to return (default `1`, must be `>= 1`).
- `--format json` — emit one structured result. `selected` contains a
  `candidates` array; `empty` contains an empty one; an unconfigured repo gets
  the distinct `not-configured` outcome. Errors stay non-zero and never emit a
  success-shaped object.

### Explicit path validation

`validate-path <path> <type>` accepts `./` spellings and absolute paths inside
the repo, then prints the canonical repo-relative POSIX path. It rejects paths
outside the repo, every tracked symlink, untracked paths, submodule-owned
paths, kind mismatches, unknown audit types, and—when configured—paths outside
that type's applicability rules. Without a tracker config it performs the Git
ownership checks directly and verifies the shipped type/kind prompt without
creating a cache; JSON output marks this as `"configured": false`.

### Global options

Both come before the subcommand:

- `--db <path>` — SQLite cache path (default:
  `<git-dir>/audit-tracker/cache.sqlite3`, outside the committed tree).
  Repopulated from `docs/work/audits/records/*.json` on every invocation.
- `--config <path>` — audit config TOML path (default:
  `docs/work/audits/config.toml`). Passing one opts that invocation in even
  without the default file.

## Data

- Schema: [`schema.sql`](./schema.sql)
- Config: `<repo>/docs/work/audits/config.toml` (consumer-owned, hand-written)
- **Audit records (source of truth):**
  `<repo>/docs/work/audits/records/<audit-type>.json` — one file per audit
  type, committed.
- **Refresh state:** `<git-dir>/audit-tracker/refresh-state.json` —
  timestamp/commit plus config-content and Git-index fingerprints, written
  every time `refresh()` runs (explicit or implicit bootstrap). The extra
  fingerprints invalidate staged path/config changes before HEAD moves. It
  lives under the git dir, so it is
  never committed and never conflicts: when it lived beside the records as a
  tracked sibling, concurrent workers conflicted on it every iteration;
  gitignoring it still left a chore per consumer. The derived SQLite cache
  lives beside it.

### Why text records, not just the SQLite file?

Multiple branches audit different files in parallel. A binary SQLite file
conflicts on every merge; per-type JSON files merge as text. Each file is
written with sorted keys and a fixed indent, so:

- Two branches audit different paths under the same type → non-overlapping
  diffs, clean text merge.
- Two branches audit different types → different files, no conflict at all.
- Two branches audit the *same* path for the same type → text conflict, which
  is the correct semantic — a human picks which audit "wins."

The CLI reloads `records/*.json` into the SQLite cache on every invocation, so
manual edits or merge resolutions are picked up automatically without a sync
step. Writers take a per-type advisory lock around the read-modify-write cycle
and atomically replace the JSON file, preventing lost updates and partial reads
when processes in the same clone finish together.

## Merging audit records

**TL;DR for resolving a conflict mid-merge:**

| Conflict marker is on… | Resolve to… |
|------------------------|-------------|
| Same `(path, audit_type)` audited twice | the **later** `last_audited_at` (unless one branch obviously did a deeper review) |
| Sort order rewritten by hand | accept either side; next CLI write rewrites in sorted order |

After resolving, do nothing else. The next CLI invocation rebuilds the cache
from the merged JSON automatically. Run `refresh` only if files were
added/renamed on the merged branch.

When you merge a branch that ran audits, expect the following:

### What auto-merges (no action needed)

- **Different audit types.** Branch A audited code-quality, branch B audited
  doc-quality → different files, zero contact.
- **Different paths under the same type.** Branch A added `app/foo.py`,
  branch B added `app/bar.py` → both land in `code-quality.json` at sorted
  positions that don't touch each other. Git handles this with a normal
  three-way text merge.

### What conflicts (and what to do)

**1. Same `(path, audit_type)` audited on both sides.**

This is rare and almost always means two people parallel-audited the same
file. Pick whichever audit reflects the deeper review — usually the **later
timestamp** (or the one whose commit actually fixed findings rather than just
recorded a no-op pass).

After accepting either side, the path will probably show up as stale on
`next --stale` — that's correct. Both branches' commits are now in main's
history, so the recorded `last_audit_commit` is necessarily older than HEAD on
the audited path. A re-audit pass will resolve it cleanly.

**2. Same path appears in different sorted positions (shouldn't happen).**

Records files are always written sorted by path; if a hand-edit broke sorting
on one side, you'll see a conflict that looks like the file was rewritten.
Resolve by accepting either side, then run any `done` on that file — the next
CLI write rewrites the JSON in sorted order.

### After the merge

1. **Don't touch the cache.** It's under the git dir. The next CLI invocation
   rebuilds it from the merged JSON automatically.
2. **Run `refresh` if files were added, renamed, or deleted on the merged
   branch.** This reconciles `paths` and applicability against
   `git ls-files`.
3. **Sanity-check counts:** `status code-quality` — the `audited=N` figure
   should equal the record count in `code-quality.json`.

### Pre-merge inspection

```bash
git diff main..feature-branch -- docs/work/audits/records/
```

## Design notes

- Renames drop audit history (cascade delete when a path disappears from
  `git ls-files`). Re-audit after a rename.
- `done` on an empty file fails with `not applicable … run refresh or check
  the config`, because `done()` gates on applicability. That is the exclusion
  working, not a stale cache — `next` no longer offers such a path.
- The config lists what's *auditable*, not what's *audited*. Adding or
  removing an audit type only changes applicability — existing audit rows are
  preserved.
- Legacy records may still contain `pick_counter`. The tracker reads and
  preserves that field but no longer advances or creates it. Candidate order
  is deterministic, while completing an audit naturally moves that path behind
  older work. Removing the shared mutation prevents otherwise independent
  branch audits from conflicting at the top of every records file.
- **Don't hand-edit records to break sort order.** The CLI rewrites in sorted
  order on every `done()`, but a manual unsorted edit lingers until the next
  write to that file and produces noisy diffs in the meantime.

## Tests

The suite lives in the Workshop checkout, not in consumer repos:
`tests/audit-tracker/`, driven by `tests/test-audit-tracker.sh` under
`make check`.
