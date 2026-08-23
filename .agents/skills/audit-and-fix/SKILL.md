---
name: audit-and-fix
description: Audit one tracked or user-named file or directory through the lens set shipped for its audit type, discuss evidence, optionally fix it, and record the reviewed commit. Use for code, documentation, README, test-quality, and code-test-coverage audits.
---

# Audit and Fix

Run a full audit loop on a file or directory for a given audit type — either the next one the tracker surfaces (optionally scoped to a subtree with `--under`), or a specific path the user names with `--path`. Use this when the user wants evidence and discussion before fixes; reviewers inspect every lens in the selected prompt file, then any approved fixes are committed and recorded against the resulting commit.

**Compatibility**: Git is required. Python 3.11+ is required for tracker selection, explicit-path validation, and recording; review-only path mode can run without it. Parallel review and task-list capabilities are optional.

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

**Branch A — `--path` is given.** Validate and canonicalize it through the tracker:

```bash
python3 .agents/skills/audit-and-fix/tracker.py validate-path <path> <audit-type> [--kind <kind>] --format json
```

Run it from the repository root and wait for completion. Do not replace it with filesystem tests or `realpath`: validation also rejects untracked paths, paths owned by a submodule, symlinks that escape the repository, unsupported type/kind combinations, and (in configured repositories) paths outside applicability rules. It accepts harmless spellings such as `./app/x.py` and in-repo absolute paths, returning their canonical repo-relative POSIX spelling.

- **Non-zero exit** — report the validation error and stop.
- **`{"outcome": "valid", "path": ..., "kind": ..., "configured": ...}`** — record the returned canonical `<path>` and inferred `<kind>`, plus `<reason>` as `user-supplied via --path`. Keep `configured`: `false` means the audit can run safely in explicit-path mode but cannot be written to the shared audit records.

If Python 3.11+ is unavailable, tracker validation and recording are unavailable. A review-only explicit-path audit may proceed only when the available Git and filesystem tools can establish that the spelling is canonical and repo-relative, the subject is tracked and owned by this repository (not a submodule), and no symlink component escapes the repository. Set `configured` to `false` for that run. If any property cannot be proved, stop; do not weaken the path guard to keep the audit moving.

**Branch B — no `--path`.** Let the tracker pick, through this skill's selector:

```bash
python3 .agents/skills/audit-and-fix/select_next.py <audit-type> [--kind <kind>] [--under <path>]
```

Run it from the repository root, and **wait for the command to finish**. If the harness hands back a still-running job instead of a completed command, poll that job until it exits — never interpret partial tool output.

Do NOT run the tracker's `next` command yourself, and do NOT pass `--path` through (that flag exists only on this skill). The tracker writes `audit_tracker:` notices to stderr the moment it starts and the candidate to stdout only when the query completes, so reading its stream as it arrives can show warnings — or nothing yet — and read as "no path to audit" while thousands are pending. The selector removes that ambiguity: it runs the tracker once to completion with both streams captured, checks the exit status before looking at stdout, validates the shape, and only then prints one JSON object.

Do not add a `refresh` step either — the tracker already auto-refreshes when its cache is stale, and says so in one of the stderr lines the selector keeps out of the selection.

Branch on the **exit status first, the JSON second**:

- **Non-zero exit** — the tracker failed, or printed something the selector would not validate; its stderr names which. Report that to the user and stop. This is never "nothing to audit".
- **`{"outcome": "not-configured", ...}`** — this repo has not opted in to tracked audits: `docs/work/audits/config.toml` does not exist (see this skill's README for the opt-in). Say so plainly — the audit runs in `--path` mode only here — and never present this outcome as "nothing to audit".
- **`{"outcome": "empty", ...}`** — the tracker said in as many words that it has no applicable path. Tell the user (mention the subtree if `--under` was set) and stop.
- **`{"outcome": "selected", "path": ..., "kind": ..., "reason": ...}`** — record `<path>`, `<kind>`, and `<reason>` from those fields, and set `configured` to `true`.

Every result also carries `diagnostics`: the tracker's stderr lines (auto-refresh notices, orphan-record warnings). Surface them if they matter to the user, but never treat one as a path or as evidence of an empty queue.

In both branches, tell the user which path was chosen and why (one sentence).

## Step 2 — Read the subject, then run every lens

**Read the target** first so you can cite concrete contents to the user:
- `kind == file` — Read the file.
- `kind == directory` — list the directory tree, read its `README.md` when one exists, and skim the contents. For large directories, sample representative files rather than reading every one.

For `readme-quality`, the audited artifact is `<subject>/README.md` and the directory is the *ground truth* it must describe accurately — read both. (Other directory modes audit the directory itself; only `readme-quality` separates artifact from ground truth.)

If a `readme-quality` subject has no `README.md`, do not run lenses whose artifact does not exist. Read enough of the directory to orient the user, then carry one high-priority finding into Step 3: the README audit targets a directory with no README, so the decision is whether to create one. If the user requests that fix, create and verify the README in Step 4; if not, continue without inventing review findings.

From this read, draft a **2–3 sentence orientation** of the subject: what the artifact is, the role it plays in the codebase, and its rough shape (size, key sections, notable contents). Keep it; Step 3 presents it to the user so they have context before ruling on findings.

Read `prompts/<audit-type>-<kind>.md` relative to this skill. Its numbered entries under `## Lenses` define the fan-out count; run every one. It may also contain a scope-framing paragraph above that heading. Substitute `<subject>` with the target path in the framing paragraph and each lens prompt.

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

The lenses are **deliberately vague** — do not add examples or narrow their scope. Let each reviewer interpret its lens broadly.

If any lens contains `<style-guide>`, resolve that placeholder before review. Start from the repository's instruction files and follow their links to the applicable code, test, documentation, or README style source; toolchain configuration can be an additional convention source. Record the exact repo-relative path or paths. If the repository has no specific source, say so explicitly in that lens instead of inventing one. Substitute this result only into the style lens; do not preload it into the other reviewers.

Give one independent reviewer each lens and run them in parallel when the harness supports it. With no subagent capability, perform the lenses sequentially in the current session and keep their findings separated until Step 3. The result and evidence requirements are identical in both modes.

When delegating, each reviewer prompt should contain:
- The scope-framing paragraph from the prompt file (verbatim, with `<subject>` substituted), if present. This tells the agent what scope to report at and which sibling audit handles adjacent findings.
- The lens text (verbatim, with `<subject>` replaced by the target path).
- The closing line `Prioritize the top five issues.`
- An anti-filler clause: `If there are fewer than five real issues, say so rather than invent filler. Be concise.`
- Only the context the reviewer truly needs to act on the lens — the subject's path, the scope framing, and (for the style lens only) the resolved convention-source paths. Do not preload conclusions or hint at what to find.

Delegated reviewers do not see the conversation, so always include the subject path. Trust them to consult instruction files and peer files themselves; do not bias them with pre-selected references.

## Step 3 — Deduplicate, prioritize, and discuss

Once all lens reviews return, merge their findings:
- Collapse duplicates (the same issue surfaced by multiple lenses).
- Reject filler that no lens actually substantiated.
- Rank from most to least important. Rank strictly by **blast radius** — how much damage misplaced trust would cause to a person or agent relying on the audited artifact — not by lens category or by how many lenses surfaced the same issue. A single deep-impact finding from one lens outranks a wording nit echoed by four.

Lead the message with a `## Subject` block that re-states the target **so the user has it in front of them before deciding** (the original Step 1 mention has scrolled away behind the fan-out):
- **Path** — the exact `<path>` and `<kind>`.
- **Why audited** — the `<reason>` from Step 1 (tracker rationale, or `user-supplied via --path`).
- **What it is** — the 2–3 sentence orientation drafted in Step 2.

Then present the findings under a `## Deduplicated & Prioritized Issues` heading, with a brief `### Non-issues rejected` subsection for concerns the lenses raised but which don't hold up.

**Stop and wait for the user.** Do not begin fixing anything. The user will tell you what (if anything) to resolve.

## Step 4 — Fix (only on user request)

If the user asks you to fix issues (e.g., "Create a TODO list to keep on track and resolve each of these issues. Use subagents to fix each issue."):

1. Create one tracking item per issue the user wants fixed. Use the harness's task list when available; otherwise maintain an explicit in-session checklist.
2. For each item: mark it in progress, delegate independent fixes in parallel when that capability exists, and give each fixer a self-contained prompt describing the issue, the file(s) involved, and the fix to apply. Without delegation, implement the items sequentially in-session. Mark each complete only after its changes are verified.
3. After all fixes land, run the project's pre-commit verification locally where applicable (the pre-commit hooks will run on commit anyway — use this step to catch issues early for trivial fixes).

If the user declines to fix anything, skip to Step 5 with no file changes.

## Step 5 — Commit the audited content

The audit record must name the commit that contains the fixes. If Step 4 changed the audited content:

1. Show `git status` and the relevant diff; preserve unrelated work.
2. Check recent history for the repository's commit convention.
3. Commit the verified fixes **without** the audit record.

If there were no fixes, keep the current `HEAD` as the reviewed commit and do not create an empty content commit.

If repository policy or the user's authorization does not permit committing, stop here with the verified working tree intact. Do not run `done` against the pre-fix `HEAD`, because that would make the new record stale as soon as the fixes are eventually committed.

## Step 6 — Mark the reviewed commit audited

When Step 1 returned `configured: false`, say that this explicit-path audit cannot be recorded until the repository opts in, and stop after any authorized fix commit. Otherwise run:

```bash
python3 .agents/skills/audit-and-fix/tracker.py done <path> <audit-type>
```

Use the canonical `<path>` and exact `<audit-type>` from Step 1. This writes the record to `docs/work/audits/records/<audit-type>.json` (the SQLite cache under `.git/` is derived, never committed).

If the tracker reports "not applicable", run:

```bash
python3 .agents/skills/audit-and-fix/tracker.py refresh
```

and retry `done` once. If it still is not applicable, report that the validated subject stopped being tracked (usually because configuration or Git state changed) and leave the already-committed fixes in place.

## Step 7 — Commit the audit record

Show `git status` and the record diff. Commit only `docs/work/audits/records/<audit-type>.json` in a separate metadata commit, using the repository's commit convention. A typical message is `chore(audits): record <audit-type> review of <path>`.

This two-commit ordering is intentional: `done` stores the current `HEAD`, so running it before the fix commit would immediately make the subject stale. The later record-only commit does not change the audited path.

---

## Notes

- `select_next.py` (beside this file) is the only sanctioned way this skill reads the tracker in Step 1. It exists because "the tracker returned nothing" and "I looked before the tracker finished" are indistinguishable to a reader of a live stream, and the second one silently ends the audit. Its tests live in the Workshop checkout (`tests/audit-tracker/`, driven by `tests/test-audit-and-fix-selector.sh`) — not in consumer repos.
- The fan-out count is set by the prompt file. Do not reduce it — each lens catches issues the others miss.
- Delegated reviewers do not see the conversation; each prompt must be self-contained with the subject path and its scope framing. Include resolved style-source paths only in the style lens; let every reviewer discover peer paths.
- Honor agents that say "fewer than five real issues" — do not pressure them into padding.
- Do not fix anything until the user explicitly directs it in Step 4.
- Never record a pre-fix `HEAD`: commit fixes first, then run `done`, then commit the record alone.
