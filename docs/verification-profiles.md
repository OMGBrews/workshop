# Verification profiles

This document defines proportionate verification expectations for repositories
and the people who maintain them. Select the profile that matches the
repository's current role and risk; it is not a maturity ladder.

Read [`verification-terminology.md`](verification-terminology.md) first. It
owns the meanings of checks, requirements, gates, lifecycle boundaries, and
outcomes used here.

## Profiles

| Profile | Select it when | Expected baseline |
|---|---|---|
| **Content or scaffold** | The repository primarily holds prose, records, examples, templates, or a starting structure and does not itself operate as active software. | A truthful definition of done; syntax, link, or structure checks only where useful; no obligatory CI theatre. |
| **Active local software** | People actively run or develop the software, but it is not published for dependants or operated as a deployed service. | One conventional local aggregate, focused tests and static checks, and CI on shared changes where collaboration risk warrants it. |
| **Shared or released software** | Other repositories or users consume its package, reusable automation, application, or released artifacts. | The active-local-software baseline plus exact-source release verification, package or build smoke tests, immutable release identity, and documented recovery. |
| **Production or deployed system** | A deployment changes a live environment or provides an operated service whose failure has user or operational impact. | The shared-or-released-software baseline plus separate deployment authorization, environment protection appropriate to risk, and post-deployment health verification. |

When more than one description fits, choose the strongest role the repository
currently performs. A repository can move between profiles when its role
changes; the label records current truth rather than an aspiration.

## Defaults, not exemptions

Profiles are starting expectations, not ceilings or waivers. Sensitive data,
destructive behavior, multiple contributors, high fan-out, or difficult
rollback justify stronger requirements at any repository size. When one of
those risks exceeds the selected profile's ordinary assumptions, strengthen
the affected requirement or select the stronger profile whose baseline best
matches the real exposure.

Repository size, contributor count, and implementation complexity are useful
signals but never override a concrete risk. Prefer the lowest profile that
describes the repository's actual role after those risks are considered.

## Avoid invented machinery

Apply the lifecycle-boundaries rule in
[`verification-terminology.md`](verification-terminology.md#lifecycle-boundaries)
to every expected baseline, including its reasoned `None` and `not applicable`
answers. In particular:

- For **content or scaffold**, identify which syntax, link, or structure checks
  are useful for the material that exists; lifecycle stages the repository
  does not perform receive the terminology document's explicit reasoned state.
- For **active local software**, provide the local evidence the software needs
  and add shared-change CI only when collaboration risk warrants it; release
  and deployment expectations follow the terminology rule when those stages
  do not exist.
- For **shared or released software**, apply release expectations only to the
  release paths the repository actually operates; deployment expectations
  follow the terminology rule when consumers, rather than this repository,
  own deployment.
- For **production or deployed systems**, apply environment protection and
  post-deployment evidence to the environments and transitions that actually
  exist; absent release or promotion stages still follow the terminology rule.

The profile selects a baseline; it does not create lifecycle stages merely to
fill a table. Record current executable truth in the repository's definition
of done and record desired machinery as a gap until it exists.

## Classification fixture

The reusable prompt and expected profile selections for reader-side trials are
in
[`verification-profiles-classification-fixture.md`](verification-profiles-classification-fixture.md).

## See also

- [`verification-terminology.md`](verification-terminology.md) — canonical
  lifecycle and verification vocabulary
- [`definition-of-done.md`](definition-of-done.md) — how repositories declare
  required evidence and current enforcement
