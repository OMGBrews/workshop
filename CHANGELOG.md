# Changelog

This file records user-visible Workshop milestones. Maintainers update it when
they create a manually initiated milestone tag or GitHub Release.

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
