# Definition of done

The evidence required before a change to public Workshop counts as done. The
suite runs from a standalone clone and needs no private upstream, hq, or other
fleet repository. This page follows
[`../definition-of-done-schema.md`](../definition-of-done-schema.md).

## Repository profile

- Declared unit: `OMGBrews/workshop`, consumed as a pinned submodule mounted at
  `workshop/` in each fleet repository. `OMGBrews/workshop-dev`, the private
  maintainer wrapper, carries its own declaration and the cloud-session
  declaration; nothing is inherited in either direction.
- Profile: [shared or released software](../verification-profiles.md#profiles).
- Production evidence: Not applicable — shared or released software; consumers
  pin commits and operate nothing on Workshop's behalf.
- Default landing route: pull request.
- Landing enforcement: platform-enforced.
- Enforcement evidence: GitHub ruleset `main requires Workshop checks`
  (id 21099180), enforcement `active`, targeting the default branch with no
  bypass actors, requiring the three status checks named below under the
  strict up-to-date policy. Observed by the maintainer on 2026-09-07 through
  `gh api repos/OMGBrews/workshop/rules/branches/main` and
  `gh api repos/OMGBrews/workshop/rulesets/21099180`.
- Strengthened for: none.

## Pre-commit feedback

None — Workshop configures no hooks or commit-time checks; `make check` is fast
enough to run before a commit.

## Landing requirements

- **Public verification suite**
  - Command: `make check`
  - Pass condition: exit 0 from a standalone clone, after the public regression
    tests, agent-surface conformance, Markdown links, JSON validation, and the
    shellcheck allow-list.
  - Applies to: every change.
  - Evidence type: automated
  - Enforcement: platform-enforced
  - Evidence state: available
  - CI status: `check (Python 3.11)`, `check (Python 3.12)`,
    `check (Python 3.13)`, from `.github/workflows/check.yml`, which runs
    `make check` on every pull request and every push to `main`.

Maintainer authorization to merge is separate from these results and is not a
requirement declared here.

### Docs-only surface

No docs-only surface is declared: `make check` walks every tracked Markdown file
and shell script, so every check is presumed to read every path.

## Release requirements

- **Verified release commit**
  - Command: `make check`
  - Pass condition: exit 0 at the exact commit being tagged; the same workflow
    runs it again on the tag push.
  - Applies to: every milestone tag.
  - Evidence type: automated
  - Enforcement: procedural
  - Evidence state: available
- **Immutable release identity**
  - Command: none
  - Pass condition: a maintainer creates the milestone tag and its GitHub
    Release by hand after the check passes, and the tag is never moved. Nothing
    is published to a registry — consumers pin commits — and there is no
    release cadence or semantic-versioning contract (`README.md`, "Checks and
    releases").
  - Applies to: every milestone tag.
  - Evidence type: manual
  - Enforcement: procedural
  - Evidence state: available

## Deployment requirements

Not applicable — Workshop deploys nothing; consumers mount a pinned commit and
carry their own deployment declarations.

## Known gaps

- No checker validates this page against the schema; clause 6 of
  `Tools/check-docs-work-conformance.sh` asserts only a heading and content.
  Remediation is owned by the `add-a-definition-of-done-conformance-check`
  brief in the maintainer wrapper's task queue.
- The transitional reading of the older single-table shape ends when every
  fleet repository has migrated; no task owns that removal yet.
- Tag immutability is procedural: the ruleset listing observed on 2026-09-07
  holds only the `main` branch ruleset, and no tag-protection rule was seen.
