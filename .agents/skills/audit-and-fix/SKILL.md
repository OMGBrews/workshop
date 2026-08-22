---
name: audit-and-fix
description: End-to-end audit workflow — pick the next path via the audit tracker (optionally scoped to a subtree with --under), or accept a user-supplied --path, fan out parallel subagent lenses (one per lens in the prompt file), discuss findings with the user, optionally fix, mark the path audited, and commit.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, TaskCreate, TaskUpdate, TaskList
---

# Audit and Fix

Run a full audit loop on a file or directory for a given audit type — either the next one the tracker surfaces (optionally scoped to a subtree with `--under`), or a specific path the user names with `--path`. Parallel subagents inspect the target through distinct lenses (the prompt file lists the lenses; most modes use 7, `readme-quality` uses 8); findings are deduplicated, discussed, and (if the user agrees) fixed and committed in one pass.

**Arguments**: `<audit-type> [--kind file|directory] [--path <path>] [--under <path>]`. If no arguments are given, print usage and stop.

## Usage

If no arguments were given, print usage and stop:

> Usage: `audit-and-fix <audit-type> [--kind file|directory] [--path <path>] [--under <path>]`
> Types: `code-quality`, `doc-quality`, `readme-quality`, `test-quality`, `code-test-coverage`
> Notes: `readme-quality` only supports `--kind directory`. `--path` overrides the tracker and targets a specific path; `--kind` is inferred from the filesystem when `--path` is given. `--under <path>` restricts the tracker's candidate set to that subtree (ignored when `--path` is given).
> Examples:
> - `audit-and-fix code-quality --kind file`
> - `audit-and-fix code-quality --path app/features/suggestions/engine.py`
> - `audit-and-fix code-quality --under app/features/suggestions`
> - `audit-and-fix code-quality --under app/features/suggestions --kind file`
> - `audit-and-fix test-quality --kind file`
> - `audit-and-fix code-test-coverage --path app/api/config.py`

Parse the arguments into `<audit-type>`, optional `--kind <kind>`, optional `--path <path>`, and optional `--under <path>`. If `--kind` is omitted and `--path` is not given, let the tracker choose both. If `--path` is given, ignore `--under`.

## Step 1 — Resolve the subject

Two branches, depending on whether the user supplied `--path`.

**Branch A — `--path` is given.** Skip the tracker and use the user-supplied path:
1. Verify the path exists (Bash `test -e <path>`). If it doesn't, stop with an error.
2. Infer `<kind>` from the filesystem: file if `test -f`, directory if `test -d`.
3. If the user also passed `--kind`, verify it matches the inferred kind; warn and use the inferred kind if they disagree.
4. Record `<path>`, `<kind>`, and `<reason>` as `user-supplied via --path`.

**Branch B — no `--path`.** Let the tracker pick, through this skill's selector:

```
python3 .agents/skills/audit-and-fix/select_next.py <audit-type> [--kind <kind>] [--under <path>]
```

Run it from the repository root, and **wait for the command to finish**. If the harness hands back a still-running job instead of a completed command, poll that job until it exits — never interpret partial tool output.

Do NOT run the tracker's `next` command yourself, and do NOT pass `--path` through (that flag exists only on this skill). The tracker writes `audit_tracker:` notices to stderr the moment it starts and the candidate to stdout only when the query completes, so reading its stream as it arrives can show warnings — or nothing yet — and read as "no path to audit" while thousands are pending. The selector removes that ambiguity: it runs the tracker once to completion with both streams captured, checks the exit status before looking at stdout, validates the shape, and only then prints one JSON object.

Do not add a `refresh` step either — the tracker already auto-refreshes when its cache is stale, and says so in one of the stderr lines the selector keeps out of the selection.

Branch on the **exit status first, the JSON second**:

- **Non-zero exit** — the tracker failed, or printed something the selector would not validate; its stderr names which. Report that to the user and stop. This is never "nothing to audit".
- **`{"outcome": "not-configured", ...}`** — this repo has not opted in to tracked audits: `docs/work/audits/config.toml` does not exist (see this skill's README for the opt-in). Say so plainly — the audit runs in `--path` mode only here — and never present this outcome as "nothing to audit".
- **`{"outcome": "empty", ...}`** — the tracker said in as many words that it has no applicable path. Tell the user (mention the subtree if `--under` was set) and stop.
- **`{"outcome": "selected", "path": ..., "kind": ..., "reason": ...}`** — record `<path>`, `<kind>`, and `<reason>` from those fields.

Every result also carries `diagnostics`: the tracker's stderr lines (auto-refresh notices, orphan-record warnings). Surface them if they matter to the user, but never treat one as a path or as evidence of an empty queue.

In both branches, tell the user which path was chosen and why (one sentence).

## Step 2 — Read the subject, then fan out to 7 subagents

**Read the target** first so you can cite concrete contents to the user:
- `kind == file` — Read the file.
- `kind == directory` — Glob the directory tree, Read the `README.md`, and skim the contents. For large directories, sample representative files rather than reading every one.

For `readme-quality`, the audited artifact is `<subject>/README.md` and the directory is the *ground truth* it must describe accurately — read both. (Other directory modes audit the directory itself; only `readme-quality` separates artifact from ground truth.)

From this read, draft a **2–3 sentence orientation** of the subject: what the artifact is, the role it plays in the codebase, and its rough shape (size, key sections, notable contents). Keep it; Step 3 presents it to the user so they have context before ruling on findings.

**Fan out one subagent per lens** — launch a subagent per lens, in parallel where the harness supports it; if the harness has no subagents, run the lenses sequentially in-session. Read the prompt file at `prompts/<audit-type>-<kind>.md` relative to this SKILL — it contains an optional scope-framing paragraph above the `## Lenses` heading and the lens prompts below it (count varies by mode; `readme-quality-directory` has 8, the rest have 7). Substitute `<subject>` with the target path in both the framing paragraph (if present) and each lens prompt.

| Audit type           | Kind        | Prompt file                                      |
|----------------------|-------------|--------------------------------------------------|
| code-quality         | file        | `prompts/code-quality-file.md`                   |
| code-quality         | directory   | `prompts/code-quality-directory.md`              |
| doc-quality          | file        | `prompts/doc-quality-file.md`                    |
| doc-quality          | directory   | `prompts/doc-quality-directory.md`               |
| readme-quality       | directory   | `prompts/readme-quality-directory.md`            |
| test-quality         | file        | `prompts/test-quality-file.md`                   |
| test-quality         | directory   | `prompts/test-quality-directory.md`              |
| code-test-coverage   | file        | `prompts/code-test-coverage-file.md`             |
| code-test-coverage   | directory   | `prompts/code-test-coverage-directory.md`        |

The lenses are **deliberately vague** — do not add examples or narrow their scope. Let each subagent interpret its lens broadly.

When delegating, each agent prompt should contain:
- The scope-framing paragraph from the prompt file (verbatim, with `<subject>` substituted), if present. This tells the agent what scope to report at and which sibling audit handles adjacent findings.
- The lens text (verbatim, with `<subject>` replaced by the target path).
- The closing line `Prioritize the top five issues.`
- An anti-filler clause: `If there are fewer than five real issues, say so rather than invent filler. Be concise.`
- Only the context the agent truly needs to act on the lens — the subject's path, and anything it would struggle to discover on its own. Do not preload conclusions or hint at what to find.

Subagents don't see the conversation, so always include the subject path. But trust them to consult AGENTS.md, style guides, and peer files themselves — don't bias them with pre-selected references.

## Step 3 — Deduplicate, prioritize, and discuss

Once all subagents return, merge their findings:
- Collapse duplicates (the same issue surfaced by multiple lenses).
- Reject filler that no lens actually substantiated.
- Rank from most to least important. Rank strictly by **blast radius** — how much damage misplaced trust would cause to a developer acting on the README — not by lens category or by how many lenses surfaced the same issue. A single deep-impact finding from one lens outranks a wording nit echoed by four.

Lead the message with a `## Subject` block that re-states the target **so the user has it in front of them before deciding** (the original Step 1 mention has scrolled away behind the fan-out):
- **Path** — the exact `<path>` and `<kind>`.
- **Why audited** — the `<reason>` from Step 1 (tracker rationale, or `user-supplied via --path`).
- **What it is** — the 2–3 sentence orientation drafted in Step 2.

Then present the findings under a `## Deduplicated & Prioritized Issues` heading, with a brief `### Non-issues rejected` subsection for concerns the lenses raised but which don't hold up.

**Stop and wait for the user.** Do not begin fixing anything. The user will tell you what (if anything) to resolve.

## Step 4 — Fix (only on user request)

If the user asks you to fix issues (e.g., "Create a TODO list to keep on track and resolve each of these issues. Use subagents to fix each issue."):

1. Create one tracking task per issue the user wants fixed.
2. For each task: mark it in progress, spawn a subagent (parallel when tasks are independent) with a self-contained prompt describing the issue, the file(s) involved, and the fix to apply. Mark it complete when the subagent returns verified changes.
3. After all fixes land, run the project's pre-commit verification locally where applicable (the pre-commit hooks will run on commit anyway — use this step to catch issues early for trivial fixes).

If the user declines to fix anything, skip to Step 5 with no file changes.

## Step 5 — Mark the path audited

Run:

```
python3 .agents/skills/audit-and-fix/tracker.py done <path> <audit-type>
```

Use the exact `<path>` and `<audit-type>` from Step 1. This writes the record to `docs/work/audits/records/<audit-type>.json` (the SQLite cache under `.git/` is derived, never committed).

If the tracker reports "not applicable" (common when `--path` targets something outside the audit type's config rules), try:

```
python3 .agents/skills/audit-and-fix/tracker.py refresh
```

and retry `done`. If it still isn't applicable, tell the user the path isn't tracked by that audit type and skip the tracker update — the audit still happened, and Step 6 will still commit any fixes.

## Step 6 — Commit

Show `git status` and `git diff` so the user can see what is about to land. Draft a commit message that follows the repo's Conventional Commits style (check `git log --oneline -10` for recent examples). Bundle the fix changes (if any) and the `docs/work/audits/records/<audit-type>.json` update in a **single commit**.

Commit with a HEREDOC message. If there were no fixes in Step 4, the commit is audit-record-only — still commit so the tracker state is shared (`chore(audits): record <audit-type> review of <path>`).

---

## Notes

- `select_next.py` (beside this file) is the only sanctioned way this skill reads the tracker in Step 1. It exists because "the tracker returned nothing" and "I looked before the tracker finished" are indistinguishable to a reader of a live stream, and the second one silently ends the audit. Its tests live in the Workshop checkout (`tests/audit-tracker/`, driven by `tests/test-audit-and-fix-selector.sh`) — not in consumer repos.
- The fan-out count is set by the prompt file (most modes 7; `readme-quality-directory` 8). Do not reduce it — each lens catches issues the others miss.
- Subagents do not see the conversation; each prompt must be self-contained with file paths, style guide paths, and peer paths.
- Honor agents that say "fewer than five real issues" — do not pressure them into padding.
- Do not fix anything until the user explicitly directs it in Step 4.
- Always bundle the `docs/work/audits/records/<audit-type>.json` update into the same commit as the fixes.
