---
status: not-started
effort: large
priority: high
dependencies: []
handoff-from: OMGBrews/llmkit-dev
---

# Support wrapper-owned audits of nested repositories

**In brief**: Allow a private project workspace to automatically choose review targets from a separately versioned product it contains, while keeping all review configuration and history private. Today the review tracker treats its own repository as both the owner of that private state and the owner of every file, so it cannot cross that boundary safely.

## Goal

Add first-class, opt-in support for auditing declared nested Git repositories while the consumer repository continues to own the audit configuration, records, cache, and skill installation. Preserve the current single-repository behavior and the ownership guards that reject undeclared submodule content.

## Context

The motivating consumer is `OMGBrews/llmkit-dev`: its private wrapper owns Workshop, planning, and maintainer workflow state, while its `library/` submodule is the public `OMGBrews/llmkit` product. The public repository must not carry audit configuration, records, agent skill links, private task state, or equivalent development machinery. Nevertheless, maintainers need `audit-next` and `audit-and-fix` to select library files and directories automatically, detect when their library commits make prior reviews stale, and keep the resulting records in the wrapper.

The tracker currently resolves one implicit repository from its process CWD: `audit_tracker.git_utils.repo_root()` caches the top-level path; configuration, records, and cache derive from it; refresh excludes gitlinks and submodule-owned paths; query identity and staleness use one path namespace and commit graph; and the selector plus audit skills assume the selected content and record belong to the same repository. Running from `library/` moves private audit state into the public repository; running from the wrapper keeps state private but correctly excludes `library/**`.

## Recommended solution

Introduce an explicit control/subject model:

- The control repository remains the CWD repository and owns `docs/work/audits/config.toml`, committed records, and derived cache. The implicit `self` subject preserves existing configuration and record paths.
- A top-level repository table declares each additional subject by stable name and a control-root-relative path. Target rules select it, for example:

  ```toml
  [repositories.library]
  path = "library"

  [[audit_types.code-quality.targets]]
  repository = "library"
  kind = "file"
  include = ["src/llmkit/**/*.py"]
  ```

- Subject paths must be lexical descendants without symlink components and resolve exactly to a Git worktree root. Missing, uninitialized, moved, non-Git, escaping, duplicate, and unknown subjects are errors. The control refresh continues to exclude declared gitlinks and submodule-owned symlinks.
- Represent candidate identity as `(repository, path)` rather than a flattened pseudo-path. Keep existing `self` records at `docs/work/audits/records/<audit-type>.json`; write additional records at `docs/work/audits/records/<repository>/<audit-type>.json`.
- Store and validate each record's audit commit against its subject repository. Add repository identity to every cache, applicability, audit, and staleness key; refresh fingerprints every subject HEAD and index plus configuration.
- Add `--repository <name>` to `next`, `status`, `validate-path`, and `done`, and pass it through `audit-next`, `audit-done`, and `audit-and-fix`. In multi-repository configuration, reject `--under` without `--repository`.
- Update the audit workflow to read both repositories’ instructions and evidence contracts, change and verify content in the subject, record the landed subject commit only when policy permits, and commit only record metadata in the control repository.
- Preserve existing single-repository configuration, CLI syntax, selection order, record layout, and path-safety behavior. Document the control/subject distinction, record layout, failure modes, and a complete nested-repository example.

## Scope

- `.agents/skills/audit-and-fix/audit_tracker/` — configuration, Git contexts, refresh, query identity, records, cache schema, and CLI.
- `.agents/skills/audit-and-fix/select_next.py` and the `audit-and-fix` workflow.
- `.agents/skills/audit-next/` and `.agents/skills/audit-done/` argument and execution contracts.
- `.agents/skills/audit-and-fix/README.md` and `.agents/skills/audit-and-fix/audit_tracker/README.md`.
- `tests/audit-tracker/` and the selector tests.

## Acceptance criteria
<!-- AC:BEGIN — DO NOT REMOVE: /task-finalize, /task-move, and the task-queue worker parse the AC list between the sentinels. -->

- [ ] A control repository can declare a nested Git repository and automatically select applicable files and directories from it without any tracked audit machinery in the nested repository.
- [ ] Candidate, validation, status, and completion operations preserve repository identity; identical relative paths in two repositories never collide.
- [ ] `done` stores the nested repository's verified commit in a record owned by the control repository, and later changes are classified using the nested repository's history rather than the control repository's history.
- [ ] Changes to any configured subject's HEAD or index invalidate inventory state, while changes confined to another repository do not make an otherwise clean audit stale.
- [ ] Missing, uninitialized, escaping, symlinked, duplicate, and non-Git repository roots fail loudly and cannot be reported as an empty queue.
- [ ] Undeclared submodules and submodule-owned symlinks remain excluded exactly as they are today.
- [ ] Existing single-repository configuration, record layout, command syntax, selection order, and path-safety behavior remain backward compatible.
- [ ] `audit-and-fix`, `audit-next`, and `audit-done` document and execute the cross-repository workflow without writing machinery into the subject or implying push, merge, gitlink-update, or release authorization.
- [ ] End-to-end tests construct a control repository plus a real nested Git repository and prove selection, validation, recording, cache invalidation, staleness, duplicate relative paths, and fail-loud behavior at the CLI and selector boundaries.

<!-- AC:END -->

## Stopping conditions

Stop when the audit-tracker and selector suites demonstrate every cross-repository case above, all pre-existing single-repository cases still pass unchanged in meaning, and the Workshop repository's required evidence is satisfied. Do not stop at a configuration parser change: the feature is incomplete until a nested subject can traverse the complete select → review/fix → subject commit → control-owned record → stale-after-subject-change lifecycle.

## Decisions

- **Q: Where does audit machinery live?** — Only in the control repository; a subject repository is never required to opt in or install anything.
- **Q: Which commit does a record name?** — The subject repository commit containing the reviewed content.
- **Q: How are existing consumers migrated?** — `self` remains implicit, current record files remain in place, and the derived cache upgrades itself.
- **Q: Are arbitrary external filesystem repositories in scope?** — No. This first feature supports separately owned Git repositories mounted beneath the control root, including submodules. Roots outside the control tree can be designed separately if a real consumer requires them.

## Out of scope

- Installing or configuring the tracker inside the nested/public repository.
- Traversing undeclared gitlinks automatically.
- Updating submodule pointers, pushing branches, opening or merging pull requests, or publishing releases.
- Supporting repository roots outside the control repository's filesystem tree.
- Changing audit lenses, prioritization policy, or the meaning of an audit type.
