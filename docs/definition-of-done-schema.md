# Definition-of-done schema

The shape of every repository's `docs/work/definition-of-done.md`: the six
sections it carries, the fields each section holds, and the vocabulary each
field draws from. Read this when writing or checking one. The standing rule is
[`definition-of-done.md`](definition-of-done.md); the terms are defined in
[`verification-terminology.md`](verification-terminology.md) and the profiles
in [`verification-profiles.md`](verification-profiles.md), and neither is
restated here. The canonical template is
[`templates/definition-of-done.md`](templates/definition-of-done.md).

## Document shape

The page opens with a level-one heading and a one-to-three-sentence scope
statement, then carries exactly these six level-two headings, spelled exactly,
in this order:

1. `## Repository profile`
2. `## Pre-commit feedback`
3. `## Landing requirements`
4. `## Release requirements`
5. `## Deployment requirements`
6. `## Known gaps`

Level-three headings are free inside a section, with one reserved name,
`### Docs-only surface`. Further level-two sections such as `## Wrinkles` or
`## See also` may follow `## Known gaps`; nothing precedes or interleaves the
six. The presence of `## Repository profile` is what distinguishes this shape
from the older single-table shape; see [Migration](#migration).

Every section states current, executable truth. Anything desired but not yet
demonstrated is a known gap, not a requirement.

## The four axes

A requirement is described on four independent axes, each its own field. A
single "status" column flattens four questions into one word, and the
flattened word is always read as the strongest of them.

| Axis | Question | Values |
|---|---|---|
| Applicability | Does this stage or requirement pertain to the repository at all? | For a stage: its requirements, or one line beginning `None —` or `Not applicable —` with the reason, per the [lifecycle-boundaries rule](verification-terminology.md#lifecycle-boundaries). For a requirement: the change surface it applies to. |
| Evidence type | Is the evidence produced by machinery or observed by a person? | `automated`, `manual` — see *Manual verification* under [core definitions](verification-terminology.md#core-definitions) |
| Enforcement | What, if anything, blocks the transition when the evidence is missing? | `advisory`, `procedural`, `platform-enforced` — see *Advisory* under [core definitions](verification-terminology.md#core-definitions) and *Procedural requirement*, *Platform-enforced requirement* under [automation and GitHub terms](verification-terminology.md#automation-and-github-terms) |
| Evidence state | Can the evidence be obtained today, and has the claim behind it been confirmed? | `available`, `unavailable`, `unconfirmed` — the latter two are the [outcome vocabulary](verification-terminology.md#outcome-vocabulary)'s states; `available` is their ordinary complement: the command can be run, or the observation was made, as the requirement describes |

The tokens are listed here because a grammar needs them; their meanings live
in the terminology document and are not restated. Two rules bind every axis:

- **Enforcement is never inferred from a workflow.** A workflow file proves
  that automation is configured; it does not prove that anything blocks a
  nonconforming transition. `platform-enforced` is declared only with an
  observation of the rule that blocks it — what was looked at, how, by whom,
  and when — recorded under `Enforcement evidence` in the repository profile.
- **Evidence state is never softened by prose.** Where a requirement's
  trustworthiness depends on a precondition — an installed hook, an initialized
  submodule, a fresh clone, a credential — the precondition is written into the
  `Pass condition` and checked by the same verdict. A green result with a
  footnote is read as green: the footnote is not in the verdict, so nothing
  that consumes the verdict ever sees it. A precondition that does not hold
  makes the requirement's evidence `unavailable`, reported as such, never as
  passed or skipped.

## 1. Repository profile

A key-value list, one key per line, these keys in this order:

- **Declared unit** — the repository this page describes, as `owner/repo`,
  and how it is consumed: a standalone clone, a pinned submodule, a published
  package. A coordination root that composes other repositories names them
  here and states that each carries its own declaration; a component names
  its root the same way. Nothing is inherited in either direction: a root does
  not take on a component's deployment requirements, and a component does not
  lean on its root's checks.
- **Profile** — one of the four names in
  [`verification-profiles.md`](verification-profiles.md#profiles), linked, not
  paraphrased: the strongest role the repository currently performs.
- **Production evidence** — required when the profile is *production or
  deployed system*: who owns the deployment and what current evidence shows it
  is operated — an environment, an endpoint, a deployment record. A web stack,
  a deployment workflow, or a deploy script is not evidence of operation; a
  repository with only those declares a lower profile and, if it wants the
  higher one, lists the missing evidence under known gaps. For the other three
  profiles, write `Not applicable — <profile>`.
- **Default landing route** — `pull request` or `authorized direct push`, the
  two routes in [`shipping-conventions.md`](shipping-conventions.md#how-work-lands).
- **Landing enforcement** — `advisory`, `procedural`, or `platform-enforced`:
  what happens to a change that reaches the default branch without its landing
  requirements satisfied. It summarizes section 3: it is the strongest
  `Enforcement` any landing requirement declares, so a section holding only
  procedural requirements cannot sit under a `platform-enforced` profile.
- **Enforcement evidence** — for `platform-enforced`, the observation: the
  ruleset or branch-protection view or API call, the actors it binds and any
  bypass it grants, who observed it and when. For the other two levels, the
  procedure, or the fact that nothing blocks. Where a platform rule is believed
  to exist but was not observed, write `unconfirmed`, declare the strongest
  level that *was* confirmed (usually `procedural`), and list the unobserved
  rule under known gaps: `unconfirmed` is an evidence state, not a fourth
  enforcement level.
- **Strengthened for** — a concrete risk (sensitive data, destructive
  behaviour, difficult rollback) that raises a requirement above the profile's
  baseline, or `none`. The strengthened requirement itself lives in its stage
  section, marked as strengthened; the profile is unchanged, per
  [defaults, not exemptions](verification-profiles.md#defaults-not-exemptions).

## Requirement grammar

Sections 2 to 5 share one grammar. A stage with nothing to require is a single
line beginning `None —` or `Not applicable —` followed by the reason: `None`
means the stage exists and asks for no evidence; `Not applicable` means the
repository does not perform the stage. Otherwise the section holds one bullet
per requirement, whose sub-lines carry these labels, in this order:

```markdown
- **Public verification suite**
  - Command: `make check`
  - Pass condition: exit 0 from a standalone clone.
  - Applies to: every change.
  - Evidence type: automated
  - Enforcement: procedural
  - Evidence state: available
  - CI status: none
```

- **Command** — the exact invocation from the repository root, or `none` for
  manual evidence. A CI status name is not a command and never goes here: a
  checker can resolve a command to a file and run it, and can do neither with
  a status name.
- **Pass condition** — what the output or artifact shows when the requirement
  is satisfied, including every precondition the verdict checks. "Exit 0" is a
  pass condition only when the command's exit status is the whole verdict.
- **Applies to** — the change surface: `every change`, a path set, a
  lifecycle transition.
- **Evidence type**, **Enforcement**, **Evidence state** — one token each,
  from [the four axes](#the-four-axes).
- **CI status** — landing requirements only: the status-check names the
  platform reports for this requirement, or `none`.

Further sub-lines may follow the fixed ones — a runtime note, a caveat that
changes how the command is run. Prose in the section is free; only the bullets
carry the label grammar.

## 2. Pre-commit feedback

Fast checks offered while preparing a local commit: a formatter, focused
tests, a hook. They are feedback, not the landing decision. A hook is per-clone
state that no committed file can vouch for, so it appears only as a
precondition inside its requirement's `Pass condition` — for example, the
command that proves the hook is installed at the effective hooks path — never
as an execution path the repository claims to run; where the hook is not
installed, the requirement's evidence is `unavailable` in that clone. Its
enforcement is at most a local commit gate, so `platform-enforced` is an error
here. Most repositories write `None — <reason>`.

## 3. Landing requirements

The evidence required before an authorized change reaches the default branch:
the canonical local command — the one conventional aggregate the profile
expects — first, and where CI runs it, the matching `CI status` names. Manual
evidence such as a review is a requirement with `Evidence type: manual` and
`Command: none`. Authorization to land is not a requirement and is not
declared here; it stays with
[`shipping-conventions.md`](shipping-conventions.md).

### Docs-only surface

The last thing in `## Landing requirements`, under this exact level-three
heading, is one of:

- the `DOCS-ONLY` sentinel block that `Tools/docs-only-diff.sh` reads: both
  sentinels at column zero and, between them, nothing but plain
  repository-relative paths, one per line, a trailing `/` marking a directory
  prefix. The block never sits inside a table, list, code fence, or indented
  text, and no guidance line goes between the sentinels — the predicate treats
  every non-blank line there as a path, and a line that matches nothing
  silently shrinks the surface;
- or one sentence stating that no docs-only surface is declared, so every
  check is presumed to read every path.

The predicate finds the block anywhere in the file; the position is a
convention for readers, so the declaration sits beside the checks it makes
inapplicable.

## 4. Release requirements

The evidence required to declare or publish an exact, immutable release
candidate: source verification at the exact commit, artifact or package smoke
tests, the identity that makes the release immutable — a tag, a version, a
digest — and where it is published. A repository whose consumers pin commits
and that publishes to no registry says so. `Not applicable —` with the reason
is the right answer for a repository that does not release.

## 5. Deployment requirements

The authorization, promotion, and health evidence required to enter an
environment, one requirement per environment or transition that actually
exists. A repository that operates nothing writes `Not applicable — <reason>`;
one whose consumers own deployment says that consumers own it. Do not invent
stages to fill the section: apply
[avoid invented machinery](verification-profiles.md#avoid-invented-machinery).

## 6. Known gaps

A bullet list. Each bullet names one protection that is missing,
advisory-only, `unavailable`, or `unconfirmed`, and links the task that owns
its remediation where one exists. A protection listed here is not also
declared as a requirement. An empty list is written as one line,
`None — <what was checked>`.

## Migration

A page is in this shape when it carries `## Repository profile`; a page
without it is in the older single-table shape. Until every repository in a
fleet has migrated, a reader or checker treats the older shape as transitional
and reads it for what it does state — commands, pass conditions — without
inferring a profile, a landing route, or an enforcement level it does not
declare. The transitional reading is removed when adoption is complete, not
kept as a permanent allowlist; the plan that drives adoption owns the removal.

## See also

- [`definition-of-done.md`](definition-of-done.md) — the standing rule this
  schema serves
- [`templates/definition-of-done.md`](templates/definition-of-done.md) — the
  canonical template
- [`verification-terminology.md`](verification-terminology.md) — the meaning
  of every token above
- [`verification-profiles.md`](verification-profiles.md) — the four profiles
  and their baselines
- [`shipping-conventions.md`](shipping-conventions.md) — authorization and the
  two landing routes
