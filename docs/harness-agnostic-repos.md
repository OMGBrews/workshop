# Harness-agnostic repositories

How every OMG Brews repository stays usable from any AI coding harness — Claude Code,
Codex, Cursor, Copilot, Gemini CLI, opencode, and whatever ships next — without
maintaining a second copy of anything. Read this before creating a repo, before adding
any agent-facing file, and before wiring a harness-specific feature into a workflow that
matters.

This is the fleet standard. The reference implementation — a private fleet repo, deliberately
unnamed in this public document — records how it applies the pattern locally in its
`docs/architecture/agents-md.md` (fleet-internal, like `devtools-propagation.md`: its layout,
its bridge mechanics, and the harness-specific things it has deliberately declined).

## Why

We do not know which harness we will be using in a year, and we already use more than
one today. A repository whose process lives in one vendor's file format is a repository
whose process evaporates the day we switch — or the day a contributor opens it in
something else. The cost of neutrality is small and paid once; the cost of a rewrite is
paid under pressure.

The goal is **not** lowest-common-denominator tooling. Use every Claude Code feature
worth using. The rule is only that the *content* — what the agent must know and do —
lives somewhere every harness can read, and the vendor-specific file is a bridge to it
rather than the thing itself.

## The three invariants

Everything below is an application of these.

1. **One source of truth, bridged — never copied.** A second copy is a drift machine,
   and a drift check is an admission that you built one. Prefer a mechanism where drift
   is impossible by construction (an import, a symlink) over one where it is merely
   detected.
2. **The canonical location is the one an open standard names.** The bridge is the one a
   single vendor names. When those are the same file, there is no bridge to build.
3. **A bridge must be inert everywhere else.** A `CLAUDE.md` is invisible to Codex; a
   symlink resolves or does not. But an `@import` line inside `AGENTS.md` renders as
   literal junk text in every non-Claude harness — that is a leak, not a bridge.

## The five agent-facing surfaces

Every repo exposes five surfaces to an agent. Each has a canonical home and, where a
holdout demands it, exactly one bridge.

| Surface | Canonical (harness-neutral) | Bridge | What breaks without the bridge |
|---------|------------------------------|--------|-------------------------------|
| **Instructions** | `AGENTS.md` at repo root | `CLAUDE.md` containing `@AGENTS.md` + Claude-only sections | Claude Code reads no project instructions at all |
| **Skills** | `.agents/skills/<name>/SKILL.md` | per-skill symlink `.claude/skills/<name> -> ../../.agents/skills/<name>` | Claude Code sees no skills |
| **Bootstrap** | a plain script, e.g. `scripts/agent/session-start.sh` | thin `.claude/hooks/*.sh` wrapper that emits the hook JSON envelope | Non-Claude sessions start on a stale checkout with uninitialized submodules |
| **Tool config (MCP)** | none — genuinely per-harness | `.mcp.json` (Claude Code, Cursor); `.vscode/mcp.json` uses a different key | Only the harnesses you wrote config for get the servers |
| **Verification** | `make check` + `docs/work/definition-of-done.md` | none needed — a command is a command | — |

The instructions and skills surfaces are settled standards. The bootstrap surface is the
one most repos get wrong, because a hook that only fires in one harness looks like it
works right up until someone opens the repo in another one.

## Surface 1 — instructions

### The layout

```text
AGENTS.md      # canonical, harness-neutral: everything every agent needs
CLAUDE.md      # thin Claude Code bridge:
               #   @AGENTS.md
               #   @devtools/docs/signal-hygiene.md
               #   @devtools/docs/definition-of-done.md
               #   @devtools/docs/verification-terminology.md
               #   <Claude Code-specific sections only>
```

### The placement rule is audience, not topic

| Content | File | Why |
|---------|------|-----|
| Overview, commands, architecture, env vars, domain concepts, coding rules, known issues | `AGENTS.md` | Every harness needs it |
| Any `@`-import line | `CLAUDE.md` | Claude-only syntax; literal junk elsewhere |
| Harness mechanics: cloud-session runbooks, subagent names, slash-command and skill pointers, `.claude/` layout rules | `CLAUDE.md` | Meaningless to other harnesses, and it keeps `AGENTS.md` lean |
| A universal rule that happens to live in an imported doc | Plain Markdown **link** in `AGENTS.md` **and** `@`-import in `CLAUDE.md` | Other harnesses follow the link; Claude gets it eagerly |

That last row is the one that gets missed, and it fails silently: the rule stays in
context for every Claude session, so nobody notices that a Codex session never learned
it. **Every `@`-imported doc needs a matching plain link in `AGENTS.md`.** All three
standing rules qualify — `signal-hygiene.md`, `definition-of-done.md`, and
`verification-terminology.md`.

### Rules

- **Never create a per-tool instruction file.** No `.cursorrules`, no
  `.github/copilot-instructions.md`, no `GEMINI.md`, no `.windsurfrules`. The standard
  exists to replace them. `CLAUDE.md` is the sole exception in this fleet, and it earns
  its place by holding content, not by redirecting.
- **Do not commit a config file whose only job is redirecting an unused harness** to
  `AGENTS.md` (`.gemini/settings.json`, `.aider.conf.yml`). Add it the day someone
  actually runs that tool. Record the decline so the next person doesn't re-litigate it.
- **Size matters, and the ceiling is not ours.** Codex silently truncates the merged
  `AGENTS.md` chain at a 32 KiB default (`project_doc_max_bytes`) — silently, meaning a
  repo that crosses it looks fine and behaves worse. Target **≤ 20 KB** for the root
  file, and count the whole always-loaded pile (root + wrapper + imports), not just one
  file.
- **Prefer a one-line pointer to a canonical doc over restating it.** Instruction files
  prepend to every session's context in every harness: size costs tokens per turn, and
  frequent edits churn prompt caches. Content the agent can derive from the code is pure
  overhead.
- **Write harness-neutral prose.** No slash-command syntax, no subagent names, no tool
  names, no assumptions about features. The section is titled "Agent guidelines", not
  "Notes for Claude", for a reason.
- **Root sentinels track the source of truth.** Scripts that locate the project root by
  probing for an instruction file must probe for `AGENTS.md`.
- **Nested files:** monorepos may nest `AGENTS.md` per sub-project — other harnesses
  resolve nearest-file-wins, and it is the only way to give a sub-project real detail
  without paying for it in every session at the root. Claude Code loads nested
  instruction files on demand **only** under the name `CLAUDE.md`, so each nested
  `AGENTS.md` needs a one-line sibling `CLAUDE.md` containing `@AGENTS.md`.

## Surface 2 — skills

Skills follow the [Agent Skills open standard](https://agentskills.io/specification):
a directory containing `SKILL.md` (YAML frontmatter + Markdown), plus optional
`scripts/`, `references/`, `assets/`.

### The layout

```text
.agents/skills/<name>/SKILL.md              # canonical — the standard's discovery path
.claude/skills/<name> -> ../../.agents/skills/<name>   # per-skill symlink, tracked in git
.claude/skills/README.md                    # generated signpost — see the rules below
```

### Shared reference files inside skills

A skill may own a canonical file that another skill or repo reads directly when
those callers must stay identical rather than merely similar:

| File | Written by | Also read by |
|------|------------|--------------|
| `task-create/_TEMPLATE.md` | `task-create` | task creation — read from inside the skill; no repo-side copy |
| `task-queue/execution-discipline.md` | the task-queue worker | `task-implement` |
| `task-finalize/check-task-readiness.sh` | `task-finalize` | `task-move` and `Tools/check-docs-work-conformance.sh` |
| `docs/focus-document.md` | `focus-update` and repository owners | `task-next`, `task-reprioritize`, `session-land`, and repository task guides |

The task template established this pattern after copied templates diverged into
seven variants. The execution discipline is live runner configuration: the
worker expands its marked blocks into one prompt, while `task-implement` reads
the same file in-session. The readiness checker similarly keeps task movement and
repository conformance on one executable rule. The focus-document contract is shared
in the other direction: writers and both selection readers need one artifact
definition, while `task-next` and `task-reprioritize` retain different ranking
judgments and stay aligned through bucket placement rather than sharing a ranking
rubric.

### Rules

- **The real directory lives in `.agents/skills/`.** Always. A skill authored under
  `.claude/skills/` is a skill only one harness can run — and since skills are where our
  process lives, that is the single most expensive mistake on this page.
- **Link per skill, never the whole directory.** Claude Code writes internal `.system/`
  files into `.claude/skills/`, which a directory-level symlink would push into the
  canonical tree. Per-skill links also leave room for real project-local skills beside
  shared ones.
- **Symlinks are tracked in git and use relative targets**, so they survive a clone.
- **`.claude/skills/README.md` says all of that in the folder where the mistake is
  made.** Someone adding a skill opens the vendor directory first — it is the one they
  have heard of — and a rule stated only here is a rule they never read. The file is
  written by `sync-skill-symlinks.sh` rather than by hand, and rewritten on every run: one
  text for the whole fleet, and an edited copy heals at the next sync instead of forking.
  It is a plain file, not a skill, so checks 7 and 8 skip it.
- **Shared skills vendored from `devtools/` follow the same rule** — the real directory
  belongs in `devtools/.agents/skills/`, and each consumer links to it.
- **Regenerate shared links with `Tools/sync-skill-symlinks.sh`.** It converts the
  legacy directory link, creates or refreshes both per-skill surfaces, preserves
  project-specific skill directories, removes stale links, and reports name
  collisions (the project-local skill wins). Re-run it after adding or renaming
  a shared skill and bumping the devtools pointer.
- **Write the body harness-neutral:**
  - No slash-command syntax in `description` or body — invocation differs per harness
    (`/name` in Claude Code, `$name` in Codex). Say "when the user invokes the *name*
    skill".
  - Refer to another skill by its bare backticked name — `task-finalize` — in prose
    mentions. Reserve the "when the user invokes the *name* skill" phrasing for
    invocation moments, and relative links (`../task-finalize/SKILL.md`) for file
    references; link only to skills guaranteed present alongside (the mirror publishes
    12 of 18 — a link from a mirrored skill to a non-mirrored one dangles in the mirror).
  - No harness-only mechanics — `$ARGUMENTS`, subagents, hooks, and specific tool names
    behave differently or not at all elsewhere. If a skill genuinely depends on one
    harness, say so in `compatibility`.
  - Claude-specific frontmatter (`disable-model-invocation`, `context`) is silently
    ignored elsewhere. Avoid it; if unavoidable, the body must still make sense without.
  - Use only spec frontmatter fields: `name` (must match the directory), `description`
    (says *what* and *when*, ≤1024 chars), and optionally `license`, `compatibility`,
    `metadata`, `allowed-tools`.
- **Keep `SKILL.md` under ~500 lines**; push detail into `references/`, which loads only
  when needed.
- **A dangling symlink is created without error and looks fine under `ls`.** It fails
  only at invocation time, as "Unknown skill" — mid-task, in the worst case silently.
  Verify with `test -e` and a readable `SKILL.md`, never a visual scan.

## Surface 3 — bootstrap

The work a session needs done before turn one: fetching, fast-forwarding, initializing
private submodules, decoding environment files, reporting where the checkout stands.

This is the surface where neutrality is usually skipped, because the hook works and
nobody opens the repo elsewhere — until they do, and the session starts on a stale
checkout with uninitialized submodules, which in this fleet means **no shared skills and
no standing rules**, with no error to say so.

### Rules

- **The logic lives in a plain script** — `scripts/agent/session-start.sh` or similar —
  runnable by a human, by CI, and by any harness, with its exit code and output intact.
- **The harness hook is a thin wrapper.** Only the vendor-specific envelope belongs in
  `.claude/hooks/`: the `hookSpecificOutput` JSON, `additionalContext`, `reloadSkills`,
  and any `CLAUDE_*` environment detection.
- **`AGENTS.md` names the command** as a first-turn step, so a harness with no hook
  system at all still has a documented path.
- **The portable event subset is small**: `SessionStart`, prompt-submit, `PreToolUse`,
  `PostToolUse`, `Stop`. Claude Code, Cursor, Codex, and VS Code Copilot all expose
  hooks, but only roughly these overlap. Anything richer is a Claude Code feature — fine
  to use, as long as the repo still functions without it.
- **A hook that never runs is a real failure mode**, not a hypothetical: it produces no
  output and no error. Any workflow that depends on bootstrap having happened needs a
  turn-one self-check the agent can run by hand, documented where context assembly puts
  it rather than where the hook would have put it.
- **The detection libraries beneath the scripts are part of this surface.** A bootstrap
  script can be perfectly neutral while the library it sources asks
  `CLAUDE_CODE_REMOTE` whether it is in a cloud sandbox — and in every other harness
  the answer is silently *no*, so location-based policy (prod access stays out of
  sandboxes) passes when it should not. The hook wrapper's translation only reaches
  the process the hook launches; long-lived shells that source the library directly
  never see it. So: **vendor environment variables are read in exactly one declared
  seam file** (e.g. `scripts/lib/harness-signals.sh`), which translates them to neutral
  `AGENT_*` names at call time — neutral wins when both are set — and every consumer
  reads the neutral helper. Adding a harness is one fallback row in the seam, never a
  new read site. The seam is also where the neutral name gets *defined*: name the
  property (`AGENT_SESSION_REMOTE`: a recognized harness-managed remote sandbox), let
  the seam own which vendor variable asserts it.

## Surface 4 — tool config

MCP server configuration is genuinely per-harness and has no neutral form: Claude Code
and Cursor read `mcpServers`; VS Code and Copilot read `.vscode/mcp.json` with a
top-level `servers` key; Codex uses `~/.codex/config.toml`.

- **Keep `.mcp.json` for the harnesses in use.** It is config, not content — the
  no-second-copy rule does not bite, because there is no source of truth to drift from.
- **Do not pre-emptively write config for harnesses nobody runs**, same as the
  instruction-file rule. This is a trigger, not a ban: the devcontainer kit was
  Claude-only under exactly this clause, with the split written down as the thing to do
  *the day a second harness self-hosted*. That day came — Oh My Pi and Codex both run in
  those containers now — and the kit split into a neutral base plus one file per harness
  (`Tools/devcontainer/build/`). Record the condition alongside the absence, so a later
  reader can tell whether it has been met.
- **Record the decision** in the repo's architecture doc, so the absence reads as a
  choice rather than an oversight.

## Surface 5 — verification

The most portable surface, and it needs no bridge: a command is a command.

- Every repo states its required evidence in `docs/work/definition-of-done.md` (see
  [`definition-of-done.md`](definition-of-done.md)).
- That file's scope is the current evidence contract, nothing more: the checks table,
  the `DOCS-ONLY` block where the repo declares one (the paths no check there reads),
  the current enforcement statement, and the minimum prose needed to run each check
  correctly — the invocation, the pass condition, any caveat that changes how you run
  it. A check's rationale, its policy history, and the standing
  constraints behind it are repo description: link them, never restate them. The file
  is read at the moment someone needs a command, and unrelated prose moves that command
  further away.
- Checks are invoked as plain commands (`make check`), never through a harness feature.
- The doc is linked from `AGENTS.md` as well as imported into `CLAUDE.md`.

## Conformance checklist

Audit a repo against these. Each asserts a **positive property of the artifact**, not an
equality that a no-op also satisfies — per [`signal-hygiene.md`](signal-hygiene.md), a
check whose pass state is reachable by the failure it exists to detect is worse than no
check, because it ends the investigation.

| # | Check | Failure means |
|---|-------|---------------|
| 1 | `AGENTS.md` exists at root and is the larger of the two instruction files | The split never happened, or content is drifting back into the wrapper |
| 2 | `CLAUDE.md` contains `@AGENTS.md` | Claude Code sees only the wrapper |
| 3 | Every `@`-imported doc has a plain Markdown link in `AGENTS.md` | Non-Claude harnesses never learn that rule |
| 4 | `AGENTS.md` contains no `@`-import lines | Junk text in every other harness |
| 5 | Root + wrapper + imports < 32 KiB, root ≤ 20 KB | Codex silently truncates |
| 6 | No `.cursorrules`, `GEMINI.md`, `.github/copilot-instructions.md`, `.windsurfrules` | A second source of truth exists |
| 7 | Skill count under `.agents/skills/` ≥ skill count under `.claude/skills/` | Skills exist that only one harness can run |
| 8 | Every `.claude/skills/*` symlink resolves to a readable `SKILL.md` | "Unknown skill" mid-task |
| 9 | Every `SKILL.md` validates against the spec | Frontmatter a stricter harness will reject |
| 10 | Bootstrap logic is reachable as a plain command | Non-Claude sessions start unbootstrapped |
| 11 | Root sentinels in scripts probe for `AGENTS.md` | The sentinel tracks the bridge, not the source |
| 12 | Vendor harness environment variables are read only in one declared translation seam; everything else consumes neutral `AGENT_*` names | Location/policy detection silently answers wrong in every other harness |
| 13 | SKILL.md bodies carry no harness-only mechanics (`$ARGUMENTS`, slash-invocations, Claude-only frontmatter) unless the skill declares `compatibility` | A skill only one harness can run looks spec-valid |
| 14 | Repositories importing Workshop's signal-hygiene and definition-of-done rules also link and import `verification-terminology.md` through that same route | Sessions use incompatible meanings for checks, gates, CI, release, and deployment |

Checks 1–9 and 13–14 are mechanizable and belong in `make check` as a single stage. Note the shape
of check 7: a count comparison, not "the directory exists" — an empty `.agents/skills/`
and a fully-populated one both exist. Both 7 and 8 count *skills*, meaning directories
and the symlinks standing in for them; a plain file on either surface — the generated
`README.md` above — is not a skill and is skipped. A dangling symlink still counts, since
that is the breakage check 8 exists to name.

> **Status:** checks 1–9 and 13–14 are implemented as the shared check
> [`Tools/check-agent-surfaces.sh`](../Tools/check-agent-surfaces.sh) — a harness-agnostic
> script that any repo runs against its own root (`bash devtools/Tools/check-agent-surfaces.sh .`
> in a consumer that mounts the tree at `devtools/`). The repo-root argument is **required**: a
> default would silently audit the wrong tree. The reference implementation wires the check
> as `make agent-surfaces` inside its `make check`; consumers without
> fleet access run the same check from the public mirror at the same path (`OMGBrewmaster/workshop`,
> `Tools/check-agent-surfaces.sh`). Checks 10–11 stay manual by design — both are judgments
> about a script's *body*, and their mechanical forms ("a file named `session-start.sh` exists",
> "the string `AGENTS.md` appears in a script") pass on a stub; the script header states the
> rationale. Check 12 *is* mechanizable — word-match the vendor variables over tracked
> files, allowlisting the seam, the vendor boundary (`.claude/`), tests, and Markdown — but
> stays repo-local because the seam's path is per-repo knowledge; the reference
> implementation enforces it as `scripts/agent/check-env-neutrality.sh`, a `make check`
> stage beside the shared check. One implementation warning, learned the hard way: scan
> with `git grep` and branch on its exit code (0 match / 1 clean / >1 check error), never a
> piped `grep` with stderr suppressed — the first version of that script passed on a regex
> parse error, a check whose pass state was reachable by the failure it existed to detect.
> A repo stops depending on someone remembering this checklist the moment its CI runs the
> check.

## Adopting this in an existing repo

1. **Inventory first.** Find every instruction file, every `@`-import, every symlink
   among them, and — critically — every *functional* reference to the literal filename:
   root-sentinel probes in scripts, doc-navigation tooling rooted at `CLAUDE.md`, CI
   comments, Markdown links. Triage hits into *load-bearing code*, *tooling behavior*,
   *links*, and *frozen artifacts* (recorded prompts, eval baselines — never edit
   those).
2. **Split, don't rename.** `git mv CLAUDE.md AGENTS.md` to preserve history, then author
   the thin wrapper per the placement table. Rewrite Claude-addressed phrasing.
3. **Slim while splitting.** You are already touching every section; this is the cheapest
   moment to get under 20 KB.
4. **Move the skills.** `git mv .claude/skills/<name> .agents/skills/<name>`, then
   `ln -s ../../.agents/skills/<name> .claude/skills/<name>`. Strip harness-specific
   phrasing from each body as you go.
5. **Split the hooks.** Neutral body out to a plain script; vendor envelope stays behind.
6. **Repoint functional references.** Sentinels, doc-navigation roots, links.
7. **Verify in more than one harness** — and record it in
   a repository-local verification log, one dated entry per harness per repo;
   the check verifies artifacts and the log is the behavior evidence. In
   Claude Code: fresh session, probe a fact
   stated only in `AGENTS.md`, confirm no import-approval dialog blocks a
   non-interactive session, confirm skills still invoke through the symlinks. Elsewhere:
   confirm the skills are discovered at all.
8. **Run the repo's required checks** and record the adoption in its architecture docs.

## Rejected alternatives

- **Symlink `CLAUDE.md -> AGENTS.md`.** Leaves no home for Claude-only content, so the
  standing-rule imports either leak into every other harness as literal text or get
  dropped; puts the full file size against Codex's truncation cap; and breaks for
  Windows contributors without `core.symlinks` plus Developer Mode. Its one advantage —
  existing links keep resolving — is outweighed, and links get repointed once,
  mechanically.
- **Two maintained copies plus a drift check.** Detects drift instead of making it
  impossible. Invariant 1.
- **Per-tool instruction files.** The standard exists precisely to replace them.
- **Waiting for Claude Code to support `AGENTS.md` natively.** The request has been open
  since August 2025 with no roadmap signal. The bridge is byte-for-byte equivalent
  today; adopt now and delete the wrapper's first line if the day ever comes.

## Ecosystem facts, as of August 2026

Re-verify before reusing this section — the Claude Code line is the one most likely to
change.

- **`AGENTS.md`** was proposed by OpenAI with Google, Cursor, Factory, and Sourcegraph in
  August 2025 and donated to the Linux Foundation's **Agentic AI Foundation** in December
  2025. Adoption is past 60,000 public repositories, with native support in 30+ tools
  including Codex, GitHub Copilot, Cursor, Jules, Gemini CLI, Devin, Zed, Amp, Factory,
  Warp, RooCode, opencode, goose, JetBrains Junie, Windsurf, and Aider.
- **Claude Code does not read `AGENTS.md`** — at any level, with no fallback. The claim
  that it falls back when `CLAUDE.md` is absent is false.
  [anthropics/claude-code#6235](https://github.com/anthropics/claude-code/issues/6235) is
  the tracker's largest open feature request. Anthropic's own memory docs instead
  document the import bridge this standard uses.
- **`@path` imports** load eagerly at session launch, resolve relative to the importing
  file, recurse to a maximum of four hops, and are skipped inside code spans and fenced
  blocks. In-project imports load silently; one resolving outside the working directory
  triggers a one-time approval dialog — which matters for non-interactive and cloud
  sessions.
- **The `AGENTS.md` spec has no import or include mechanism.** This single fact drives
  the whole wrapper design.
- **Codex truncates** the merged chain at 32 KiB (`project_doc_max_bytes`), global
  `~/.codex/AGENTS.md` included. Repeatedly reported as the top production issue.
- **Several harnesses read only the root file** — Copilot code review, Copilot CLI, early
  Windsurf. Anything universal belongs at the root.
- **Agent Skills** was published as an open specification in December 2025 and is
  supported by ~40 products, including Claude Code, Codex, Copilot, VS Code, Cursor,
  Gemini CLI, goose, and opencode. `.agents/skills/` is the cross-client discovery
  convention. Claude Code does not yet read it
  ([anthropics/claude-code#31005](https://github.com/anthropics/claude-code/issues/31005));
  it reads `.claude/skills/`, and follows per-skill directory symlinks correctly.

## See also

- A repository-local harness-verification log — the behavior half of adoption
  step 7, recording what real sessions in non-Claude harnesses actually did
  with each surface
- [`signal-hygiene.md`](signal-hygiene.md) — how to know a step actually happened; the
  source of the checklist's "assert a positive property" rule
- [`definition-of-done.md`](definition-of-done.md) — the required-evidence surface
- [`verification-terminology.md`](verification-terminology.md) — shared meanings for
  checks, requirements, gates, CI, release, and deployment
- [`documentation-style-guide.md`](documentation-style-guide.md) — house conventions
- The fleet-internal propagation guide is deliberately not linked here because
  Workshop is standalone and does not publish the private consumer inventory.
- [AGENTS.md](https://agents.md/) — the standard's site
- [Agent Skills specification](https://agentskills.io/specification) — the authoritative
  skill format reference
- [Claude Code memory docs](https://code.claude.com/docs/en/memory) — `CLAUDE.md`
  mechanics and the documented interop bridge
