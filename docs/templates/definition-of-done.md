# Definition of done

<!-- Delete every guidance comment except the two DOCS-ONLY sentinels, then fill
     in each section. The shape is defined by `docs/definition-of-done-schema.md`,
     the terms by `docs/verification-terminology.md`, and the profiles by
     `docs/verification-profiles.md`, all in the Workshop mount. Link them by your
     repository's mount path (for example
     `../../workshop/docs/definition-of-done-schema.md`); no relative link resolves
     both from this template's home and from your docs/work/, which is why this
     file carries none.

     A complete page for a content-or-scaffold repository is short, and no line
     of it names a command the repository does not have:

         # Definition of done

         The evidence required before a change to this cookbook counts as done.

         ## Repository profile

         - Declared unit: `example/recipes`, a standalone clone.
         - Profile: content or scaffold.
         - Production evidence: Not applicable — content or scaffold.
         - Default landing route: authorized direct push.
         - Landing enforcement: procedural.
         - Enforcement evidence: nothing blocks a push to `main`; the procedure is this page.
         - Strengthened for: none.

         ## Pre-commit feedback

         None — no hooks or local checks are configured.

         ## Landing requirements

         None — no automated checks exist; the author reads the diff before pushing.

         ### Docs-only surface

         No docs-only surface is declared; every check is presumed to read every path.

         ## Release requirements

         Not applicable — nothing is released or published.

         ## Deployment requirements

         Not applicable — nothing is deployed.

         ## Known gaps

         None — a link check would be useful once the cookbook cross-references itself.
-->

<!-- Scope statement, 1-3 sentences: what this page covers and who reads it. -->

## Repository profile

<!-- One key per line, in this order.
     Declared unit: this repository as owner/repo and how it is consumed. A root
       that composes other repositories names them and says each carries its own
       page; nothing is inherited in either direction.
     Profile: one of the four names in the profiles document.
     Production evidence: required for a production-or-deployed profile — who
       operates the deployment and the current evidence that it is operated, never
       a stack, workflow, or script. Otherwise "Not applicable — <profile>".
     Default landing route: "pull request" or "authorized direct push".
     Landing enforcement: advisory, procedural, or platform-enforced. It is the
       strongest Enforcement any landing requirement below declares.
     Enforcement evidence: for platform-enforced, the observation — what was looked
       at, by whom, when, and any bypass it grants. A rule believed but not observed
       is "unconfirmed": declare the strongest confirmed level and list the rule
       under Known gaps.
     Strengthened for: a concrete risk, or "none". The strengthened requirement
       itself lives in its stage section; the profile does not change. -->

- Declared unit:
- Profile:
- Production evidence:
- Default landing route:
- Landing enforcement:
- Enforcement evidence:
- Strengthened for:

## Pre-commit feedback

<!-- Fast local checks or hooks, declared as feedback, not the landing decision.
     A hook is per-clone state: name it only as a precondition inside the
     requirement's Pass condition (the command that proves it is installed), and a
     missing hook makes the evidence unavailable, never passed. Most repositories
     write one line: "None — <reason>". -->

None —

## Landing requirements

<!-- One bullet per requirement, the canonical local command first, sub-lines in
     this order:
       - **Requirement name**
         - Command: <exact invocation from the repository root, or none>
         - Pass condition: <what the output shows, including every precondition
                            the verdict checks>
         - Applies to: <every change | a path set | a transition>
         - Evidence type: automated | manual
         - Enforcement: advisory | procedural | platform-enforced
         - Evidence state: available | unavailable | unconfirmed
         - CI status: <status-check names, or none>
     A workflow file never implies an enforcement level. Or write one line:
     "None — <reason>". -->

- **Verification suite**
  - Command:
  - Pass condition:
  - Applies to:
  - Evidence type:
  - Enforcement:
  - Evidence state:
  - CI status:

### Docs-only surface

<!-- Keep exactly one of the two forms. Either list the paths no check in this
     repository reads between the sentinels below — one plain repository-relative
     path per line, a trailing "/" for a directory prefix, no globs, and nothing
     else between the sentinels, because Tools/docs-only-diff.sh reads every
     non-blank line there as a path — or delete the two sentinel lines and write
     one sentence: "No docs-only surface is declared; every check is presumed to
     read every path." -->

<!-- DOCS-ONLY:BEGIN — paths no check in this repo reads. DO NOT REMOVE. -->
<!-- DOCS-ONLY:END -->

## Release requirements

<!-- Evidence to declare or publish an exact, immutable release: the same grammar
     as landing requirements, without CI status. If the repository does not
     release, one line: "Not applicable — <reason>". -->

Not applicable —

## Deployment requirements

<!-- Authorization, promotion, and health evidence for each environment that
     actually exists, same grammar. If nothing is deployed, or consumers own
     deployment, one line: "Not applicable — <reason>". -->

Not applicable —

## Known gaps

<!-- One bullet per missing, advisory-only, unavailable, or unconfirmed
     protection, linking the task that owns its remediation where one exists.
     Or one line: "None — <what was checked>". -->

-
