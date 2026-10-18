<!--
Template: the cloud-sessions rule file, deployed as .claude/rules/cloud-sessions.md
in a superproject. Claude Code loads every file in .claude/rules/ at launch, and
no other harness reads that folder, which is why Claude-only cloud mechanics live
here rather than in AGENTS.md. Copy this file there, replace the <PLACEHOLDERS>,
and delete these guiding comments. Pair it with session-start.sh and
settings-hooks.json from this template directory. Paths below are written
relative to the repository root; if you turn one into a Markdown link, write it
for the deployed location (../../docs/... from .claude/rules/).
The worked example is a private fleet repo whose docs/operations/claude-web-workflow.md
carries the full workflow and decision record.
-->

# Working from Claude Code on the web (cloud sessions)

Cloud sessions run behind a git proxy: work lands on `main` through PRs, direct pushes are blocked, and only repos attached to the session are writable. This superproject is the session's primary repo — the web UI's PR flow covers it — and everything else is one ritual away.

- **The checkout starts as stale as the environment cache** (the snapshot embalms the clone; sessions don't re-clone). The `SessionStart` hook fetches `origin` and, when loss-free (clean tree, no local commits), fast-forwards the working branch and re-syncs submodules — read its first-turn output to know where the checkout stands before trusting shared state.
- **Submodules start uninitialized.** The session bootstrap at `scripts/agent/session-start.sh` initializes public submodules automatically — Claude Code runs it from a `SessionStart` hook, and in any other harness you run it yourself on turn one: `bash scripts/agent/session-start.sh`. Private ones need session scope first: call `add_repo` for `<OWNER/PRIVATE-SUBMODULE-REPO>`, then `git submodule update --init <path>`. Until the shared-tools tree (`<MOUNT>`, conventionally `workshop/`) is initialized, the `.claude/skills/*` symlinks and the standing-rule links beside this file in `.claude/rules/` dangle — see the next bullet, which is what to do when a session starts that way.
- **Turn-one check before relying on a shared skill or the standing rules.** Run `git submodule status`: a leading `-` on the shared-tools submodule means it was uninitialized when the skill registry was built, so every `.claude/skills/*` symlink dangled and **no shared skill is invocable this session** even after you populate the files. (`git -C <MOUNT> log -1` is not a valid check — it walks up to this repo and reports *its* commit, which looks like success.) The hook asks for a registry reload when it initializes a submodule, so this only bites when the hook did not run — which has happened, silently, with no error notice (2026-07-29). When it does: **say so unprompted**, run `bash scripts/agent/session-start.sh` to populate the files — that is the bootstrap itself, a plain command needing no hook and no harness — then read the skill's `SKILL.md` from disk and follow it directly rather than reporting the command missing. Check the standing rules in the same breath — rule files load once at launch and are not re-read when a dangling link starts to resolve, so if `<MOUNT>/docs/signal-hygiene.md`, `<MOUNT>/docs/definition-of-done.md`, or `<MOUNT>/docs/verification-terminology.md` is not already in your context, read it from disk after the bootstrap.
- **Pushing submodule changes needs scope too**: `add_repo` for the submodule's repo, then push a `claude/<task>` branch of the submodule. `main` is never a push target from a cloud session.
- **Ship with `/ship`, not direct pushes.** It runs the required checks, opens cross-linked PRs for every changed repo whose checks pass against its recorded pointers, defers a parent whose checks depend on an unmerged child (branch pushed, PR opened only after that child merges), and stops; on the maintainer's explicit go-ahead it merges child-first (squash), bumping each pointer to the **post-merge SHA**. A deferred parent's PR then waits for its own go-ahead.
- **Pointer discipline**: a submodule gitlink only ever references commits reachable from that submodule's default branch — never a PR-branch SHA (squash merges orphan those). Nothing rolls a pointer on a schedule; a lag is reported, never healed. <OPTIONAL: name the project's pointer-check workflow here; see pointer-check.yml in the template directory.>
- **Verification in the cloud**: <NAME WHICH DOCUMENTED CHECKS RUN IN A CLOUD SESSION, WHICH REQUIREMENTS THEY SATISFY, AND WHICH NEED A LOCAL MACHINE — secrets, host services (e.g. a host Ollama), licensed tooling (e.g. the Unity Editor)>.
