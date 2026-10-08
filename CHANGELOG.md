# Changelog

This file records user-visible Workshop milestones. Maintainers update it when
they create a manually initiated milestone tag or GitHub Release.

- `Tools/check-markdown-links.sh` percent-decodes targets before testing that
  they exist, so `[guide](my%20docs/guide.md)` finds `my docs/guide.md`; the
  shared extractor still returns targets byte for byte. A repository may list
  sources to skip in a root `.markdown-links-skip` file — one plain path per
  line, a trailing `/` for a directory, `#` comments for the reason — and each
  skipped source is named. Wildcards, absolute paths, and `..` entries exit 2;
  an entry that matches no tracked Markdown file fails the check. A source
  outside the link grammar still exits 2, but no longer stops the run: every
  other source is checked and reported first. The final `Markdown links valid`
  line is unchanged.
- `Tools/rewrite-moved-markdown-links.sh` no longer reads footnote definitions
  (`[^1]:`) as reference definitions, in either mode; links in footnote text
  are handled like any other inline link. Rewrite mode no longer corrupts an
  inline link that does not start its line: it used to copy stray bytes of the
  old target in front of the rebased one (`See [a](../x.md)` could become
  `See [a](../x../../x.md)`). Documents moved by an earlier rewrite, including
  kaizen journals migrated by `Tools/migrate-kaizen-journal.sh`, may carry such
  links and are worth a link check.

- `Tools/check-command-signal-hygiene.sh` judges a command verdict-bearing only
  when the verdict-bearing program is what actually runs. Reading a test script
  (`grep -n x tests/verify-a.sh | head`, `cat tests/test-x.sh | head`) or naming
  a runner as an argument (`grep -n pytest notes.txt | head`) is no longer
  denied by the f1 or f3 screen. Runs reached through a subshell, substitution,
  assignment, `env`/`time`/`timeout`/`nice`/`sudo`, an interpreter
  (`bash -x script.sh`), `python -m`, or a package runner (`uv run`, `npx`,
  `pnpm <bin>`) are still denied. Consumers get the narrower screen on their
  next Workshop pointer advance.

- A repository's root is now an audit target: the directory `.`, selected only
  by the literal include pattern `"."` (no wildcard reaches it, so existing
  configs gain no new candidates). `include = ["."]` on a `readme-quality`
  directory rule audits the top-level `README.md`, of the control repository or
  — with `repository = "<name>"` — of a declared nested repository, which
  `--repository <name> --path .` also targets. A root audit is stale after any
  content commit, but in the control repository a commit that only changes
  audit records no longer stales the root or any directory above
  `docs/work/audits/records/`. The tracker's derived cache rebuilds itself once
  on upgrade.

- The audit skill family can audit a separately versioned repository nested
  inside the one that holds the audit config — a submodule or a plain nested
  clone — without installing anything in it. Declare it under
  `[repositories.<name>]` in `docs/work/audits/config.toml`, point target
  rules at it with `repository = "<name>"`, and pass `--repository <name>` to
  `audit-and-fix`, `audit-next`, `audit-done`, the selector, or the tracker's
  `next`, `status`, `validate-path`, and `done`. Its records join the existing
  `docs/work/audits/records/<type>.json` layout one level down, at
  `records/<name>/<type>.json`, still committed in the control repository, and
  its staleness follows its own history. A missing or uninitialized nested
  repository is an error, never an empty queue. JSON results now always carry
  a `repository` field (`"self"` for the control repository), and the tracker's
  derived cache rebuilds itself once on upgrade. Single-repository configs,
  records, commands, and selection order are unchanged.

- Added the `thought-create` and `thought-finalize` skills for a repository's
  `docs/work/thoughts/` folder. `thought-create` captures a note there,
  creating and seeding the folder where it is absent. `thought-finalize`
  decides with the user what a thought becomes — a task, a problem record, an
  idea document, a record, an amendment, a kaizen entry, or nothing — hands it
  to that artifact's owner, and deletes the thought in the same commit. The
  thoughts-folder seed is `docs/templates/thoughts/README.md`. A new
  idea-document genre ships with them: `docs/templates/idea-doc.md`, a
  `docs/templates/ideas/README.md` seed for `docs/planning/ideas/`, and a
  matching section in the documentation style guide.

- `Tools/claude-code-web.py validate` now accepts a Claude Code on the Web
  session's proxy origin, `http://local_proxy@127.0.0.1:<port>/git/<owner>/<repo>`.
  Inside a session, `git remote get-url origin` returns that address, so every
  configured repository failed validation in its own cloud session with "origin
  is not a supported GitHub repository URL".

- `Tools/cloud-git-lfs.sh hydrate` now also requires the index to agree with
  the hydrated files. `git lfs pull` exits 0 even when its index update fails,
  which leaves `git status` listing every pulled file as modified. A pull now
  repairs those entries, and `--verify` reports them. The census also stops
  counting uncommitted edits to LFS files as unhydrated placeholders.

- Added `Tools/cloud-git-lfs.sh` and `docs/cloud-git-lfs.md` for repositories
  that track files with Git LFS in Claude Code on the Web. One `session` call
  installs the credential fallback git-lfs needs before the session proxy can
  authorize it, installs git-lfs's `pre-push` hook under Workshop's
  `core.hooksPath`, and hydrates with a positive census. It is meant to replace the
  per-repository copies of plunk-godot's fallback helper once consumers adopt it.

- Added a canonical prose template and the `problem-create`, `problem-status`,
  and `problem-audit` skills for recording and reassessing flaws that exist
  today. Kaizen routing and the seeded problems guide now share that template,
  while retirement remains evidence-gated through `kaizen-resolve`.

- Reshaped the definition-of-done convention into a short always-loaded rule
  and an on-demand schema, `docs/definition-of-done-schema.md`. Every
  repository's `docs/work/definition-of-done.md` now answers six questions in a
  fixed order — repository profile, pre-commit feedback, landing requirements,
  release requirements, deployment requirements, known gaps — with
  applicability, evidence type, enforcement, and evidence state as separate
  fields, per-clone preconditions inside the verdict, and the `DOCS-ONLY`
  block in a defined position. A canonical template and a scratch-repository
  test ship with it, and Workshop's own page is the first migrated example.

- Moved the task queue out of the public repository. Maintainer planning for
  Workshop work, including cross-repo handoffs addressed to Workshop, now lives
  in the private `OMGBrews/workshop-dev` wrapper; `docs/work/` keeps only the
  definition of done and the consumed-by declaration.

- Made standard cloud-session bootstrap adoption a validated invariant. A
  `configured` repository that declares the public Workshop submodule must now
  carry both canonical kit scripts byte-for-byte, both executable, and register
  the wrapper as a complete `SessionStart` hook object. The relationship is read
  from `.gitmodules` rather than a resolved symlink, so an uninitialized mount —
  the shape that leaves every shared skill silently unregistered for a whole
  session — is a failure rather than an exemption, and both public Workshop URL
  spellings are recognized.

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
