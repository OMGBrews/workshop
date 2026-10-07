# audit-and-fix

Operator and maintainer reference for installing, configuring, and
troubleshooting Workshop's audit skill family. Read this when adopting the
family in a repository; the executable workflow lives in [`SKILL.md`](./SKILL.md).

The family runs a full audit loop on one file or directory — picked by the
bundled audit tracker, or named explicitly — through a prompt-defined set of
review lenses, then discusses, fixes, and records the result. Three skills ship
together:

- **`audit-and-fix`** — the full loop: pick → run every lens → deduplicate →
  discuss → (optionally) fix and commit → mark audited → commit the record.
- **[`audit-next`](../audit-next/SKILL.md)** — just print the next path to audit.
- **[`audit-done`](../audit-done/SKILL.md)** — just mark a path as audited.

The tracker that powers them ships beside this README, in
[`audit_tracker/`](./audit_tracker/README.md). One symlink delivers skill and
engine together; consumers invoke everything through the
`.agents/skills/audit-and-fix/…` path, never a mount-named route.

## Installation and prerequisites

Install the three directories `audit-and-fix`, `audit-next`, and `audit-done`
as one family. `audit-next` and `audit-done` call the engine inside
`audit-and-fix`; installing either sibling alone leaves a skill that can be
discovered but cannot run. Workshop's `Tools/sync-skill-symlinks.sh` links the
complete shared roster and therefore preserves this dependency automatically.
If a consumer creates selected links by hand, it must link all three.

Git is required. Python 3.11 or newer is required for tracker selection,
explicit-path normalization and safety validation, and shared audit records.
Parallel-agent and task-list APIs are optional: `audit-and-fix` runs lenses and
fixes sequentially with an inline checklist when those capabilities do not
exist.

Without Python, an agent may still perform a review-only audit of a path the
repository has already established as canonical, tracked, and locally owned,
but it cannot claim tracker validation or write an audit record. If ownership
or canonical spelling cannot be proved with the available Git and filesystem
tools, stop instead of reviewing a path that could belong to a submodule or
escape through a symlink.

## Opting a repo in

Tracker-guided audits are **opt-in per consumer repo, declared by the config's
existence** ("declared, not assumed"): create `docs/work/audits/config.toml`
and the skills become tracker-aware; without it they say so plainly and fall
back to `--path`-only audits.

In an unconfigured repository, `validate-path` still canonicalizes and checks
an explicit subject against Git ownership and the shipped prompt set. Its JSON
result carries `"configured": false`; the lens review and any requested fixes
can proceed, but `done` cannot create a shared record until the repository opts
in.

```toml
# docs/work/audits/config.toml
[audit_types.code-quality]
description = "Code style, clarity, structure, and correctness."
[[audit_types.code-quality.targets]]
kind = "file"
include = ["app/**/*.py", "scripts/**/*.py"]
exclude = ["**/__pycache__/**"]

[[audit_types.code-quality.targets]]
kind = "directory"
include = ["app/**", "scripts"]
```

Rules:

- Each type needs at least one `[[…targets]]` table: `kind` (`file` or
  `directory`), a non-empty `include` glob list, optional `exclude`.
- Globs are gitignore-style: `**` spans whole segments (`app/**` matches
  `app/x` but not `app` itself); `*`/`?` stay within one segment.
- The shipped prompt set under [`prompts/`](./prompts/README.md) is the closed
  vocabulary of types — a config naming a `<type>-<kind>` combination with no
  prompt file is rejected. New combinations are Workshop contributions
  (PR + pin bump), not per-repo forks.

## Auditing a nested repository

A wrapper repository can audit a separately versioned Git repository mounted
beneath it — a submodule or a plain nested clone — while keeping every piece
of audit machinery to itself. The repository that holds the config is the
**control** repository (`self` in tracker output); a declared nested
repository is a **subject**. Nothing is installed or written in the subject
except the fixes a review makes.

```toml
# docs/work/audits/config.toml in the wrapper (control) repository
[repositories.library]
path = "library"             # control-root-relative; must be the subject's Git root

[audit_types.code-quality]
[[audit_types.code-quality.targets]]
kind = "file"                # no repository key: the control repository (self)
include = ["scripts/**/*.py"]

[[audit_types.code-quality.targets]]
repository = "library"
kind = "file"
include = ["src/**/*.py"]    # relative to library/'s own root
```

- **Names** use lowercase letters, digits, and hyphens; `self` is reserved.
  Declared paths must be plain descendants of the control root, must not
  overlap, and must resolve exactly to a Git worktree root with no symlink
  on the way.
- **Identity** is a repository plus a path relative to that repository's
  root, so `tool.py` in the wrapper and `tool.py` in `library/` are distinct
  candidates and records.
- **Commands** take `--repository <name>`: `next`, `status`, `validate-path`,
  `done`, the selector, `audit-next`, `audit-done`, and `audit-and-fix`.
  Without it, `next` and `status` cover every repository and
  `validate-path`/`done` mean `self`. With repositories declared, `--under`
  needs `--repository`. A control-relative path into a subject
  (`library/src/x.py`) is refused with the subject-relative spelling to use
  instead.
- **Staleness** follows the subject's own history: `done --repository
  library` records `library/`'s `HEAD` after checking it is in that
  repository's history, and later `library/` commits make the record stale.
  Changes confined to the wrapper never stale a `library/` audit, and the
  reverse holds too.
- **Failures are loud.** A missing, uninitialized, moved, plain, symlinked,
  or commit-less subject is an error (exit 2) for every command that reads
  it, never an empty queue. Commands scoped to another repository, such as
  `--repository self`, keep working.
- **Ownership guards are unchanged.** The control repository's own paths
  still exclude every gitlink, declared or not, and every tracked symlink;
  an undeclared submodule is never traversed.

The workflow: run `audit-and-fix` from the wrapper root; it selects
`library` content, the review and fixes happen in `library/`, the fixes are
committed **inside** `library/`, `done --repository library` records that
commit, and only `docs/work/audits/records/library/<type>.json` is committed
in the wrapper, by explicit pathspec. The wrapper's now-modified gitlink is
left alone. Pushing `library/`, opening or merging pull requests, moving the
submodule pointer, and releasing are separate, separately authorized steps.

If subject work lands through a squash-merged or rebased pull request, the
recorded commit leaves the subject's history and the path resurfaces as
stale. Once the landed commit is checked out in the subject, `audit-done
<path> <type> --repository <name>` re-records it without a new review.

## Where state lives

| Path | What | Committed? |
|------|------|------------|
| `docs/work/audits/config.toml` | the opt-in declaration + type rules | yes, hand-written |
| `docs/work/audits/records/<type>.json` | per-path audit history | yes, text-mergeable |
| `docs/work/audits/records/<repository>/<type>.json` | the same, for a declared nested repository | yes, in the control repository |
| `<git-dir>/audit-tracker/cache.sqlite3` + `refresh-state.json` | derived cache | no — outside the tree, nothing to gitignore |

Records are JSON written with sorted keys and a fixed indent for deterministic
diffs; the merge playbook is in [the engine README](./audit_tracker/README.md).

## Running it

From the consumer repo root:

```bash
python3 .agents/skills/audit-and-fix/select_next.py code-quality        # validated JSON pick
python3 .agents/skills/audit-and-fix/tracker.py next doc-quality -n 5 --format json
python3 .agents/skills/audit-and-fix/tracker.py validate-path ./app/api.py code-quality --format json
python3 .agents/skills/audit-and-fix/tracker.py done <path> <type>      # record an audit
python3 .agents/skills/audit-and-fix/tracker.py status code-quality     # counts
python3 .agents/skills/audit-and-fix/tracker.py next code-quality --repository library --format json
python3 .agents/skills/audit-and-fix/tracker.py done src/core.py code-quality --repository library
```

In an unconfigured repo, legacy text-mode tracker commands exit 4. JSON-mode
`next` and the selector instead return `{"outcome": "not-configured"}` with a
successful exit, distinct from "no candidates" and from failures, so an
unconfigured repo can never be told "nothing to audit".
