# Changelog

This file records user-visible Workshop milestones. Maintainers update it when
they create a manually initiated milestone tag or GitHub Release.

- Standardized cloud setup scripts on `scripts/agent/cloud-setup.sh`, with a
  versioned absolute-path dialog stub and validator coverage for the stub and its
  executable target.

- Defined four proportionate verification profiles for content or scaffold,
  active local software, shared or released software, and production or
  deployed systems. The guidance selects by current role and risk, strengthens
  defaults for sensitive or difficult-to-recover work, and avoids inventing
  automation for lifecycle stages a repository does not perform. A reusable
  classification fixture and checked bidirectional navigation support
  reader-side trials.

- Standardized `docs/work/tasks/focus.md` as a compact direction document with one
  public contract, a `focus-update` writer skill, and mechanical conformance checks for
  its 15-line ceiling, labelled deferrals, dates, and task-brief links. Task selection,
  reprioritization, and session landing now share the artifact definition without
  sharing their distinct ranking behavior.

- Published the `ship` skill. Coordinated pull-request delivery — child-first
  merges, post-merge pointer bumps, and the parent declarations in
  `docs/work/consumed-by.md` that drive them — is now a shared skill any
  consumer receives by moving its Workshop pin and re-running
  `Tools/sync-skill-symlinks.sh`. `Tools/normalize-remote.sh` and its
  regression test came with it, so the skill has no dependency outside this
  repository, and `docs/session-return-durability.md` publishes the
  cloud-session return measurements its Phase 5 rules rest on. The
  `consumed-by` grammar narrowed at the same time: a declaration line is an
  `owner/repo` pair, and the unused `fleet` reserved word is gone from both
  the skill and `check-docs-work-conformance.sh`.

- Added the repository-owned Claude Code Web environment standard. Every fleet
  repository can now archive a configured or explicit negative state at
  `docs/work/claude-code-web.md`; the shared validator checks its sentinel JSON,
  secret-safe variable declarations, network policy, exact setup script, and
  Claude settings projection, and can render human or normalized fleet views.
  The narrow `claude-web-session` skill uses that declaration for environment
  and repository selection without implying permission to launch or apply it.

- Added the fleet's canonical verification terminology: checks produce
  evidence, definitions of done state requirements, and boundary-qualified
  gates control commit, landing, release, or deployment transitions. Standing
  instruction delivery, cloud-session recovery, conformance checks, shared
  task guidance, and a reusable classification fixture now use and enforce the
  same vocabulary.

- The devcontainer build kit now gives Claude Code, Codex, and Oh My Pi the
  same prompt-entry behavior: `Enter` inserts a newline and `Shift+Enter`
  submits. Existing harness configuration is preserved, startup validation
  checks the mappings, and the devcontainer guide documents live application
  plus VS Code's one-time host-terminal binding.

- `sync-skill-symlinks.sh` now generates `.claude/skills/README.md` in each
  consumer, the signpost saying that folder is symlinks and that skills are
  authored in `.agents/skills/`. It names the shared tree as actually mounted
  and is rewritten on every run, so the text cannot drift between repos.
  `check-agent-surfaces.sh` and `check-skill-roster-freshness.sh` now count
  skills — directories and the symlinks standing in for them — so a plain file
  on either surface is neither reported as a broken bridge link nor announced
  as a stale skill roster.

- `migrate-kaizen-journal.sh` now rebases supported relative Markdown links as
  it relocates entries, with an atomic refusal for ambiguous active link syntax.
  `check-markdown-links.sh` shares that bounded grammar, skips and names
  repository-escaping targets and unavailable submodule mounts, and validates
  populated submodule targets.

- Shipped the fleet's public shipping convention: `docs/shipping-conventions.md`
  states how finished code and docs land — gates first, direct push from an
  authorized local session or a PR where one is required, consent never implied
  — and is summarized in the standing `docs/definition-of-done.md` so every
  standing-rule importer receives it through its existing Workshop mount.
- Retired the legacy whole-tree documentation audit skill. Its judgment half is owned by the
  `audit-and-fix` skill's `doc-quality` and `readme-quality` lenses, and
  whole-tree link integrity by `Tools/check-markdown-links.sh`; the auto-fix
  pass and the guaranteed style-source fallback were dropped by decision.
- Workshop is now the hand-authored source of truth; public contributions use

- Workshop is now the hand-authored source of truth; public contributions use
  the pull-request workflow and private vulnerability reporting.
- `Tools/devcontainer/` publishes a project-neutral `install-packages.sh` and a
  mount-agnostic `post_install.sh`, so a consuming image can source its whole
  container layer from Workshop instead of keeping a private copy.
- New `audit-and-fix` skill family — `audit-and-fix`, `audit-next`, and
  `audit-done` — with the audit tracker that powers them bundled inside the
  skill (`audit_tracker/`, stdlib-only Python ≥ 3.11, no venv needed). A repo
  opts in by committing `docs/work/audits/config.toml`; records live at
  `docs/work/audits/records/<type>.json` as text-mergeable JSON; the derived
  SQLite cache lives under the git dir. Repos without the config get a
  distinct "not opted in" outcome and validated `--path`-only audits. The
  tracker now exposes machine-readable selection and path validation, the
  workflow has sequential fallbacks for harnesses without subagents, and audit
  records are committed after the content commit whose `HEAD` they store.
- The `docs/work/` conformance checker gained clause 17: an opted-in
  `docs/work/audits/` must carry its declaring `config.toml` and parseable
  JSON records.

## Release policy

Tags and GitHub Releases are maintainer-initiated, immutable identifiers for
the exact checked commit. Continuous integration validates each pushed tag with
`make check`; Workshop makes no release-cadence or semantic-versioning
compatibility promise.
