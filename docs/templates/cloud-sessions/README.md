# Cloud-session bootstrap kit

Everything a superproject needs so Claude Code on the web (cloud) sessions work as smoothly as local ones — and so every adopting project gets the *same* wiring. Read this when enabling cloud development on a project. The worked example is a private fleet repo whose `docs/operations/claude-web-workflow.md` carries the full workflow and the decision record behind this kit (2026-07-16).

## Why a kit instead of shared code

Cloud sessions start with **no submodules initialized**, so anything that bootstraps the shared-tools tree cannot live inside it — each project carries its own copy of the bootstrap. This kit keeps the copies identical and gives them one canonical home. The `/ship` skill itself is shared the normal way (per-skill symlink) and needs no copying.

## The pieces

| File | Copy to | Then |
|------|---------|------|
| [`agent-session-start.sh`](./agent-session-start.sh) | `scripts/agent/session-start.sh` | `chmod +x` it |
| [`session-start.sh`](./session-start.sh) | `.claude/hooks/session-start.sh` | `chmod +x` it |
| [`settings-hooks.json`](./settings-hooks.json) | merge the `hooks` key into `.claude/settings.json` | keep the project's existing keys |
| [`claude-md-cloud-section.md`](./claude-md-cloud-section.md) | a section in the project's `CLAUDE.md` | fill the `<PLACEHOLDERS>`, delete the guiding comments |
| [`pointer-check.yml`](./pointer-check.yml) | `.github/workflows/` (optional) | one job per **public** upstream submodule |

### The bootstrap is a plain script; the hook is only a bridge

**`agent-session-start.sh` is the bootstrap.** Everything that fetches, fast-forwards, initializes submodules, and reports pointer lag lives there, and it runs as an ordinary command with no harness at all:

```bash
bash scripts/agent/session-start.sh
```

**`session-start.sh` is a ~90-line Claude Code wrapper** that adds nothing but the vendor envelope: the JSON object on stdout, `additionalContext`, `reloadSkills`, and the translation of `CLAUDE_PROJECT_DIR` / `CLAUDE_CODE_REMOTE` into the neutral `AGENT_PROJECT_DIR` / `AGENT_SESSION_EPHEMERAL`.

They are split because a `SessionStart` hook is a **whole agent-facing surface that exists in one harness only** ([`harness-agnostic-repos.md`](../../harness-agnostic-repos.md), surface 3). Before the split, a Codex, Cursor, or opencode session opened on a checkout as stale as the environment snapshot with `devtools/` uninitialized — which by each project's own turn-one check means no shared skills and no standing rules — with nothing printed to say so. Now every harness runs the same bootstrap; only the envelope is Claude's.

**Deploy both halves.** A repo carrying the wrapper without `scripts/agent/session-start.sh` is half-adopted, not opted out: the hook fires and nothing bootstraps. The wrapper detects exactly that and reports it loudly (naming the `cp` to run) rather than exiting quietly, and `/ship`'s kit drift check covers both files. A repo that uses no Claude Code may deploy the neutral half alone — that is a real opt-out, and the drift guard stays silent about a wrapper that was never deployed.

**Both halves have the byte-for-byte contract**, and the drift guard lives in the neutral script — the half that always runs — checking both deployed copies every session.

**Upgrading from the pre-split kit**: bump the shared-tools pointer, then deploy `agent-session-start.sh` to `scripts/agent/session-start.sh` and re-copy `session-start.sh` over the old hook. Between the bump and the redeploy the old hook's own drift guard fires (it compares against the new wrapper template and they differ), so the transition announces itself; following its `cp` remedy installs the wrapper, and the wrapper's missing-bootstrap report then names the second copy.

## Adoption checklist

1. Bump the project's shared-tools pointer (the submodule, conventionally `devtools/`, `workshop/` for a mirror consumer) to a commit that carries `/ship`, then run `bash <mount>/Tools/sync-skill-symlinks.sh` from the project root — the `/ship` symlink appears alongside the other shared skills. On a repo with no `.claude/` directory yet, `mkdir .claude` first: the script treats a missing `.claude/` as a wrong-directory guard and refuses to run.
2. Copy the bootstrap, the wrapper, and the settings block (rows 1–3). The bootstrap fetches `origin`, and in an **ephemeral session** (`AGENT_SESSION_EPHEMERAL=true`, which the wrapper sets from `CLAUDE_CODE_REMOTE=true`) fast-forwards the working branch to the remote default branch when that is provably loss-free — clean tree, no local commits, `--ff-only` — then re-syncs initialized submodules to the moved pointers; a cached cloud environment restores the clone from its snapshot, so without this the checkout can be up to a week stale at session start. Everywhere else (local machines, resumed sessions carrying work) it only *reports* how far the local default branch trails — never a reset — and initializes only *uninitialized* submodules, so it changes nothing about local development beyond the fetch. The same run also reports **pointer lag** for each *declared* submodule edge (one carrying `branch = <name>` in `.gitmodules`): the gitlink this superproject records against that branch's tip, via a single `git ls-remote` per declared edge — no fetch, no clone, and no checkout of the child, so it works in a fresh cloud clone where the child is not even attached to the session. A difference prints both short SHAs and the remedy; a check that could not run (a private child answering 403, a timeout) prints too, because silence has to mean *checked*. Everything the hook reports is delivered in one JSON object on stdout (`hookSpecificOutput.additionalContext`), which is also how it requests the skill-registry reload described below; with nothing to report and no reload to ask for it prints nothing at all.
3. Add the CLAUDE.md section (row 4): name which submodule repos are private (they need `add_repo` before `git submodule update --init` works in a cloud session) and which of the project's checks run in the cloud versus only on a local machine.
4. **Private submodules without per-session ceremony (recommended)**: configure `SUBMODULE_READ_TOKEN` in the project's cloud environment — see the next section. Without it, every fresh cloud session pays a self-serve bootstrap (`add_repo` + init, ~ten tool calls) before the shared skills exist.
5. Optional hardening, per public upstream submodule: the pointer-check workflow (row 4). **Do not add a Dependabot `gitsubmodule` backstop.** A scheduled pointer writer contradicts the explicit-consistency model; a lagging pointer is reported, not healed.
6. In the project's first cloud session: confirm the hook ran (its output lands in the session's context) and that `add_repo` covers every repo the session must push to.

## Drift guard: the copies stay identical, checked, not promised

The two bootstrap scripts are the only kit files with a byte-for-byte contract — `settings-hooks.json` is *merged* into an existing `settings.json` and `pointer-check.yml` is *parameterized* per project, so neither can be mechanically diffed against its template without permanent false alarms. The scripts can be, and are, at two seams:

- **Every session**: the neutral script's own last lines compare **both** deployed copies against their templates and print a `DRIFT` warning naming the offending file into the session's context — the agent sees it on turn one and can reconcile immediately. The check ships inside the template, so every adopter inherits it by performing the copy step they already perform. It lives in the neutral half deliberately: that is the one that always runs, whatever the harness. When `devtools/` is uninitialized the comparison is skipped; that is not a silent hole, because the init loop has already reported why devtools is missing. A deployed file that is *absent* is likewise not drift — a repo using no Claude Code carries no wrapper.
- **Every `/ship`**: the skill re-runs the same comparisons as required checks (and asserts each deployed copy is executable), so a drifted bootstrap cannot ride along with a ship. `/ship` is symlinked from devtools, never copied, so this seam cannot itself drift.

Neither seam covers a **half-adopted** kit — a wrapper with no neutral script under it. That one the wrapper reports itself, at runtime, in the session's context.

**Verifying a hook change in a cloud session needs the environment cache invalidated first.** A cached environment restores the workspace from a filesystem snapshot instead of cloning, so the hook that *executes* at session start is the snapshot's copy — a session opened right after a hook change runs the **old** hook, then fast-forwards the new one onto disk, which looks like a green run of a change that never ran. Force a rebuild first (bump the version stamp in the environment's setup-script stub, or change the network config); the rebuild clones main fresh. Confirmed the hard way while validating the `reloadSkills` change (2026-07-29).

Direction of reconcile, both seams: **the template is canonical**. A hotfix made to a deployed copy is upstreamed into the template first, then redeployed template → copy. A deliberate template improvement reaches each project as a devtools bump followed by the redeploy the next session's `DRIFT` warning asks for.

Escalation path, deliberately not built now: if drift ever slips past both seams, the next step is a wrapper CI job diffing the two files with a read token for the shared-tools repo (see [`secrets-in-workflows.md`](../../secrets-in-workflows.md)) — per-repo secret plumbing that the session seam makes unnecessary today.

## `SUBMODULE_READ_TOKEN`: private submodules from turn one

The session's git proxy scopes access to repos *attached to the session*, and only the agent can attach more (`add_repo`, mid-session) — so a private submodule like the shared-tools tree cannot initialize before the first turn, and anything it carries (the shared skills, the standing-rules import) is missing until the agent runs the bootstrap ritual. A setup script cannot fix this: it runs behind the same proxy, earlier.

**And "missing until the bootstrap runs" understates it for skills specifically.** Populating the shared-tools tree mid-session restores the *files* but not the slash commands: `/ship` answers `Unknown skill: ship` even though `<mount>/.claude/skills/ship/SKILL.md` is readable on disk (observed 2026-07-29). The skill registry is built from `.claude/skills/*`, and a per-skill symlink that dangled when it was built stays unregistered — no later `git submodule update` re-registers it.

**The hook now asks for the rebuild.** A `SessionStart` hook may return `reloadSkills: true`, which reloads all skills after the hook completes and before Claude receives the first user message. `session-start.sh` requests it exactly when that run initialized or re-synced a submodule, which is why its stdout is a single JSON object rather than loose lines (its "Output contract" header explains the shape; the report itself rides in `additionalContext`, unchanged). So on a session where the hook *runs*, the links resolve and the commands register.

**Mid-session syncs are covered by git hooks, not this hook.** A sync landing while a session is open — the standard workspace sync, or a manual pull of a consumer commit — can change the skill entry set under a running roster. Oh My Pi snapshots its roster at session start and re-scans only on `/reload`; Claude Code's live-change detection misses the symlink-shaped transitions shared tools produce; Codex refreshes automatically. `Tools/check-skill-roster-freshness.sh`, wired as `post-merge`/`post-checkout`/`post-rewrite` git hooks through `core.hooksPath`, prints the reload instruction into the git command's output exactly when the entry set changed. The bootstrap above writes the session-start baseline and the hook path every session; `sync-skill-symlinks.sh` wires the path and warns for its own run — so a session that syncs mid-flight is told to run `/reload-skills` (Claude Code) or `/reload` (Oh My Pi) instead of silently serving old names.

**What that cannot cover: the hook not running at all.** On a 2026-07-29 cloud session the platform fired **no `SessionStart` hooks** — both wired hooks produced zero output, no timeout or error notice appeared anywhere, and the second hook's product (a decoded `.env`) was absent from disk despite its preconditions holding. Not a timeout (this hook measures ~0.8s against its 120s budget), not a token problem (the same init succeeded when run by hand), not drift (the deployed copy was byte-identical to this template). Restoring that session from the archive fired no hooks either. A hook that never runs cannot request a reload, so **the announcement belongs where context assembly puts it**: the CLAUDE.md section of this kit carries a turn-one self-check, because `claudeMd` contents *did* reach that session's context when hook output did not. The degraded path, once detected, is to run `bash .claude/hooks/session-start.sh` by hand and then **read the skill's `SKILL.md` from disk and follow it directly** — worth naming rather than discovering mid-task. Verify with `git submodule status` — a leading `-` means uninitialized, and `git -C devtools log -1` is *not* a valid check (it walks up to the parent repo and prints the superproject's commit, which looks like success).

**If you are reading this because it happened again, that is the trigger to report it upstream.** One occurrence was judged too rare to file (2026-07-29) and the self-check above was built instead; a second means it is not a one-off. The evidence to file with is in the paragraph above, plus the unexplained detail from that session: the `@devtools/docs/signal-hygiene.md` import *did* resolve into turn-one context while `devtools/` was empty on disk. Nothing accounts for that, so do not rely on the standing rules surviving a no-hooks start — check, per the self-check.

The fix is a read-only credential the hook can use directly:

1. **Mint a fine-grained PAT** (GitHub → Settings → Developer settings → Fine-grained tokens): resource owner = the org; repository access = *only* the private submodule repo(s) (e.g. the shared-tools repo); permissions = **Contents: Read-only**, nothing else. Set an expiry you'll actually rotate on.
2. **Add it to the project's cloud environment** (environment settings → Environment variables):

   ```text
   SUBMODULE_READ_TOKEN=github_pat_...
   ```

3. **Allow `github.com`** in the environment's network policy if it uses a custom allowlist — the fallback fetches github.com directly, deliberately bypassing the session proxy.

Behavior and exposure, so the tradeoff is explicit:

- The hook uses the token **only** when a normal init fails in a cloud session (`CLAUDE_CODE_REMOTE=true`), and only for `https://github.com/...` submodule URLs. Local sessions never touch it.
- Bootstrap read only: after the clone, the token is scrubbed from the superproject's and the submodule's git config, and it is masked in any error output. **Pushing** to the private submodule still requires `add_repo` — the token cannot write.
- Like every environment variable, it is readable by anything running in the session. Scope it to read-only on tooling repos and it is the smallest credential in the environment; rotate it when it expires or when in doubt.

## Local + cloud, one behavior

- The hook never touches an initialized submodule, so local checkouts are never yanked to the recorded pointer mid-task — and the token fallback is gated on `CLAUDE_CODE_REMOTE`, so local sessions never use it.
- The pointer-lag report covers **declared edges only**. An entry with no `branch` key is pinned on purpose — every shared-tools edge, since 2026-07-28 — and a pinned pointer is written by an explicit propagation, never by a session, so the hook stays silent about it. The `branch` key is the whole discriminator: no repo is named and no URL is read to decide (the shared-tools tree's `submodule-currency.md` and `devtools-propagation.md` docs carry the model, where the mount predates them this paragraph is the whole rule).
- **A lagging pointer is information, not a fault.** Pointers move only when someone asks, so a report means nobody has asked yet — the point is that the lag be visible at the one moment someone is present to act on it. What that prevents is a session reading a child through a stale pointer and seeing a tree missing work that exists on the child's remote (observed 2026-07-21: real upstream work invisible behind a stale pointer). The hook reports and mutates nothing; taking the update is the reader's call.
- `/ship` is for PR-flow contexts (cloud sessions, protected branches). Where direct push is the documented local convention, the standard commit → push → bump flow and hq's `./scripts/sync/push.sh` sweep remain first-class.
- The pointer discipline applies everywhere, both flows: a submodule gitlink only ever references commits reachable from that submodule's default branch.

## See also

- The templates index in the consuming repository — the other copy-paste templates
- [`secrets-in-workflows.md`](../../secrets-in-workflows.md) — if a pointer check needs a read token for a private upstream
- The private `ship` skill is deliberately not linked from public Workshop.
