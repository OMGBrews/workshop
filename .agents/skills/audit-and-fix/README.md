# audit-and-fix

Run a full audit loop on one file or directory — picked by the bundled audit
tracker, or named explicitly — through several parallel review lenses, then
discuss, fix, and record. Three skills ship in this family:

- **`audit-and-fix`** — the full loop: pick → fan out lens subagents →
  deduplicate → discuss → (optionally) fix → mark audited → commit.
- **[`audit-next`](../audit-next/SKILL.md)** — just print the next path to audit.
- **[`audit-done`](../audit-done/SKILL.md)** — just mark a path as audited.

The tracker that powers them ships beside this README, in
[`audit_tracker/`](./audit_tracker/README.md). One symlink delivers skill and
engine together; consumers invoke everything through the
`.agents/skills/audit-and-fix/…` path, never a mount-named route.

## Opting a repo in

Tracker-guided audits are **opt-in per consumer repo, declared by the config's
existence** ("declared, not assumed"): create `docs/work/audits/config.toml`
and the skills become tracker-aware; without it they say so plainly and fall
back to `--path`-only audits.

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

## Where state lives

| Path | What | Committed? |
|------|------|------------|
| `docs/work/audits/config.toml` | the opt-in declaration + type rules | yes, hand-written |
| `docs/work/audits/records/<type>.json` | per-path audit history | yes, text-mergeable |
| `<git-dir>/audit-tracker/cache.sqlite3` + `refresh-state.json` | derived cache | no — outside the tree, nothing to gitignore |

Records are JSON written with sorted keys and a fixed indent for deterministic
diffs; the merge playbook is in [the engine README](./audit_tracker/README.md).

## Running it

From the consumer repo root:

```
python3 .agents/skills/audit-and-fix/select_next.py code-quality        # validated JSON pick
python3 .agents/skills/audit-and-fix/tracker.py next doc-quality -n 5   # raw tracker output
python3 .agents/skills/audit-and-fix/tracker.py done <path> <type>      # record an audit
python3 .agents/skills/audit-and-fix/tracker.py status code-quality     # counts
```

A repo without the config gets exit code 4 from the tracker and
`{"outcome": "not-configured"}` from the selector — distinct from "no
candidates" and from failures, so an unopted-in repo can never be told
"nothing to audit".
