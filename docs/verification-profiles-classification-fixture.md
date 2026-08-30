# Verification profiles classification fixture

This fixture provides one exact prompt and expected mapping for checking whether
a fresh agent can select the canonical verification profiles. Use it for
reader-side trials; it is observational evidence, not a language-model
conformance gate.

## Exact prompt

Give the agent [`verification-profiles.md`](verification-profiles.md), then copy
the following block without adding profile hints:

```text
Select the canonical verification profile for every numbered repository.
Name the profile and briefly explain which role or risk signal controls the
choice. Apply the profile guidance to say where an explicitly reasoned `none`
or `not applicable` answer is appropriate. Do not assume facts not stated in
the fixture.

1. A repository contains a personal cookbook in Markdown. Broken relative
   links would be inconvenient, but it builds, publishes, and deploys nothing.
2. A small command-line program is actively developed and run by its author.
   It is not distributed, consumed by another repository, or deployed.
3. A package is imported by twelve other repositories and published with
   versioned artifacts. Consumers need a documented rollback path.
4. A web service is deployed to production and handles user traffic. Its
   deployment changes a live environment and a health check can inspect the
   running result.
5. A two-file Markdown repository stores incident recovery credentials and
   other sensitive operational data. It has one maintainer and no software
   build, release, or deployment.
6. A template repository scaffolds new projects. It contains shell and JSON
   templates whose syntax can be checked, but the repository itself never
   releases or deploys an artifact.
7. A local data-cleanup tool is not published or deployed, but one command can
   irreversibly delete source records and recovery is difficult.
```

## Expected mapping

Equivalent wording is acceptable when it preserves the controlling role or
risk and does not invent lifecycle machinery.

| # | Expected classification |
|---|---|
| 1 | **Content or scaffold.** Link checking may be useful; release and deployment are explicitly reasoned as absent under the linked terminology rule. |
| 2 | **Active local software.** Its active executable role calls for a conventional local aggregate and focused checks; release and deployment are absent rather than obligations to automate. |
| 3 | **Shared or released software.** High fan-out and versioned consumption make exact-source release evidence, smoke tests, immutable identity, and recovery the baseline. |
| 4 | **Production or deployed system.** Live operational impact calls for separate deployment authorization, risk-appropriate environment protection, and post-deployment health evidence. |
| 5 | **Content or scaffold with stronger requirements.** Sensitive data overrides the repository's small size, but does not manufacture build, release, or deployment stages; those remain explicitly reasoned as absent. |
| 6 | **Content or scaffold.** Useful syntax checks fit the material; release and deployment are absent for the repository itself. |
| 7 | **Active local software with stronger requirements.** Destructive behavior and difficult rollback strengthen authorization and recovery controls around the mutation, while release and deployment remain absent when they are not real stages. |

## Recording a trial

Record the repository commit, Workshop commit, harness and version, exact
prompt, faithful response, comparison with this mapping, and any limitation. A
model response is evidence for that observed session. The durable control
remains the canonical document and its mechanically checked navigation.

## See also

- [`verification-profiles.md`](verification-profiles.md) — canonical profile
  definitions used by this fixture
- [`verification-terminology.md`](verification-terminology.md) — canonical
  lifecycle and outcome vocabulary
