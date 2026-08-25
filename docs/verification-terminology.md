# Verification terminology

This document defines the shared language for checks, requirements, gates,
continuous integration, releases, and deployments. Read it before describing
how a change or artifact becomes eligible to move through its lifecycle.

## The compact rule

> Checks produce evidence. Definitions of done state which evidence is
> required. Gates control named boundaries. CI runs checks; repository rules
> enforce selected landing requirements. Authorization permits actions;
> approval may satisfy a requirement. Release and deployment have separate
> gates.

Four layers must remain distinct:

1. **Evidence** — what was evaluated and what result it produced.
2. **Policy** — which evidence and decisions are required.
3. **Enforcement** — what actually prevents a transition.
4. **Authorization** — who or what permits the transition to be attempted.

A passing check supplies evidence. It does not by itself satisfy every policy,
prove enforcement, authorize an action, or approve a candidate.

## Lifecycle boundaries

The core change lifecycle is:

```text
working tree -> commit -> land
                 |         |
              feedback   shared default branch
```

Released and deployed systems may continue through optional, separate paths:

```text
land -> release -> publish -> promote -> deploy -> post-deployment verification
```

The sequence is descriptive, not mandatory. A repository may never release or
deploy. A deployment may materialize configuration or another identified
change without a formal release. `None` and `not applicable`, with a reason,
are better than invented automation.

- **Commit** creates a local Git checkpoint. Commit-time feedback should
  normally be fast because the checkpoint is cheap and reversible.
- **Land** moves work onto the shared default branch, by pull-request merge or
  an authorized direct push.
- **Release** declares an exact, immutable, versioned candidate or artifact.
- **Publish** makes an identified release or artifact available through a
  channel or registry.
- **Promote** advances the same immutable artifact's eligibility or channel
  without rebuilding it.
- **Deploy** materializes an identified artifact, configuration, or other
  change in an environment.
- **Post-deployment verification** gathers evidence from the running result
  after deployment has mutated the environment.

## Core definitions

| Term | Meaning |
|---|---|
| **Verification** | The umbrella activity of gathering evidence about a change, candidate, artifact, environment, or running system. |
| **Check** | A repeatable evaluation that produces a result. A check is evidence-producing machinery, not authority. |
| **Test** | A check that exercises behavior against an expectation. |
| **Smoke test** | A small test of critical-path behavior or basic operability. The name describes scope and depth, not enforcement. |
| **Suite** | A named collection of checks or tests. |
| **Manual verification** | Evidence observed by a person and identified as manual rather than presented as automated. |
| **Requirement** | Policy stating which evidence, authorization, or approval is needed. |
| **Definition of done** | A repository's current, executable statement of required evidence, applicability, and real enforcement. It is policy, not a check, suite, or gate. |
| **Gate** | A control at a named lifecycle boundary that prevents the transition until its requirements are satisfied. |
| **Advisory** | A result or recommendation that informs a decision but is not required by either procedure or platform enforcement. |
| **Authorization** | Permission granted to an actor to perform an action or transition. |
| **Approval** | An explicit positive decision by an authorized reviewer or authority. Approval may satisfy a requirement; it is not a synonym for authorization or a passing check. |

Use a boundary-qualified name when the context is not unmistakable:

- a **local commit gate** controls one local Git commit invocation;
- a **landing gate** controls entry to the shared default branch;
- a **release gate** controls declaration or publication of a release;
- a **deployment gate** controls entry to an environment.

Avoid the unqualified word *gate* for a workflow, hook, script, suite,
definition of done, or status result. Those things may participate in a gate;
they are not automatically gates themselves.

## Automation and GitHub terms

| Term | Meaning |
|---|---|
| **Pre-commit hook** | A local Git event mechanism. It may run checks and block one local commit, but it can be absent or bypassed and does not establish fleet-wide landing enforcement. |
| **Commit-time feedback** | Fast evidence offered while preparing a local commit. It becomes a local commit gate only when a configured mechanism actually blocks that commit invocation. |
| **Continuous integration (CI)** | An automation environment that runs workflows in response to repository events. |
| **Workflow** | An event-driven automation definition. A workflow contains jobs. |
| **Job** | A scheduled unit of workflow execution containing steps. |
| **Step** | One command or action within a job. |
| **Status check** | A reported result attached to a commit or ref. |
| **Configured required status check** | A status selected by a GitHub rule. Configuration alone does not prove that the rule currently binds a particular actor or landing route. |
| **Confirmed binding landing requirement** | A configured requirement for which authoritative evidence also shows active enforcement, applicable scope, and no relevant bypass. |
| **Procedural requirement** | Policy enforced by participants following the documented procedure. |
| **Platform-enforced requirement** | Policy blocked mechanically by repository, environment, or delivery-platform configuration. |

GitHub may display a status as required while a ruleset is in evaluation mode,
does not apply to the branch, or permits the actor to bypass it. Say “GitHub is
configured to require `verify`” for configuration evidence. Say “the landing
gate requires `verify`” only after the binding behavior is confirmed for the
route being described.

CI does not authorize a commit, push, pull request, merge, release, or
deployment. A user instruction or standing workflow delegation supplies that
authorization. A reviewer approval can be one landing requirement without
being either the authorization to merge or evidence that automated checks ran.

## Supporting mechanisms

| Term | Meaning |
|---|---|
| **Preflight** | A non-mutating readiness evaluation before an action. It is a gate only when something consumes its result to block a named boundary. |
| **Classifier** | Machinery that selects applicability or routing. It does not prove that the selected work passed. |
| **Generator** | Machinery that creates or updates artifacts. A generator is not a check; a separate comparison can check that its output is current. |
| **Build** | A transformation of source and inputs into an artifact. Successful completion and separate artifact checks can provide evidence, but the output-producing process is not itself a check. |
| **Monitor** | Machinery that observes ambient or external state over time. It is not change verification unless a named transition consumes its result. |

## Outcome vocabulary

These are semantic states, not mandatory literal output strings. A tool may
print `ok`, `success`, or `FAIL`; reports map that label to the applicable state
without flattening distinct outcomes.

| Outcome | Use when |
|---|---|
| **Passed** | The check ran and its stated expectation was satisfied. |
| **Failed** | The check ran and its stated expectation was not satisfied. |
| **Errored** | The check could not complete normally, so it produced no trustworthy pass/fail result. |
| **Cancelled** | Execution started or was scheduled and then intentionally stopped. |
| **Skipped** | Automation chose not to run the check. State whether the skip was expected; an unexpectedly skipped required check is not a pass. |
| **Not applicable** | The requirement does not pertain to this candidate or transition. This is a policy/applicability result, not an execution result. |
| **Unavailable** | Required evidence cannot currently be obtained or observed. |
| **Unconfirmed** | An external-state claim has not been verified with authoritative evidence. |

GitHub's `success`, `failure`, `cancelled`, and `skipped` conclusions normally
map to passed, failed, cancelled, and skipped. Infrastructure or configuration
failures that prevent a check from completing are errored even if a platform
uses a broader failure label. An expected path-filter skip can correspond to
not applicable only when a classifier and policy establish that fact; an
unexpected dependency or configuration skip remains missing required evidence.

## Verification and validation

Fleet usage intentionally keeps **verification** as the evidence-gathering
umbrella. **Validation** is the subset that asks whether an outcome is fit for
its intended user or operational need.

When the traditional contrast matters, use:

- **conformance verification** — does the result meet the specified
  requirement?
- **validation** — does the result meet the intended need?

Ordinary English remains ordinary English. Input validation, schema validation,
and a control-flow condition that gates the next branch do not become lifecycle
terms merely because they share a word. Rename metaphors such as “acceptance
gate” when a reader could mistake them for lifecycle policy.

## Preferred phrasing

| Say | Avoid | Why |
|---|---|---|
| “The check passed.” | “The gate passed.” | Evidence ran; a boundary control did not execute as a result. |
| “`make check` is the local verification suite.” | “`make check` is the gate.” | A command produces evidence. |
| “The landing requirement is procedural.” | “CI protects main.” | A workflow file does not prove binding enforcement. |
| “GitHub is configured to require `verify`; binding enforcement is unconfirmed.” | “`verify` blocks every merge.” | Configuration, enforcement, scope, and bypass are separate claims. |
| “The pull request was approved; the merge is authorized.” | “Approval means it can merge.” | Approval can satisfy a requirement without granting the actor permission. |
| “The classifier selected the docs lane; the link check passed.” | “The docs gate passed.” | Applicability and evidence are different results. |
| “The generator ran; the freshness check passed.” | “Generation passed.” | Output production and output verification are separate. |
| “The change is ready to land.” | “The change is safe to merge.” | Landing covers both merge and authorized direct push. |
| “Deployment completed; the health check passed.” | “Release passed.” | Release, deployment, and post-deployment evidence are separate. |

## Examples

### Pull request with required CI

`make check` and the CI workflow run the same verification suite. The workflow
reports a `verify` status. A binding branch rule, confirmed active for the
actor and route, makes that status part of the landing gate. A maintainer's
merge authorization remains separate.

### Authorized direct push

The repository's definition of done requires `make check` procedurally. The
authorized local session runs it and pushes to the default branch. The landing
gate is procedural: there is required evidence and authorization, but no
platform control blocks a nonconforming push.

### Optional local hook

A pre-commit hook runs a formatter and focused tests. It provides commit-time
feedback and may control that clone's local-commit boundary. Because another
clone can omit or bypass it, the hook is not evidence of a fleet-wide landing
gate.

### Build, release, and deployment

CI verifies an exact source commit, builds once, and checks the artifact. A
release declares its immutable identity; publication exposes it in a registry;
promotion changes its eligible channel without rebuilding; deployment places
it in production; post-deployment verification checks the running service.
Each boundary keeps its own requirements and authorization.

### Generator, classifier, and monitor

A docs classifier selects which checks apply. A generator refreshes an index.
A freshness check compares the committed index with generated output. A monitor
reports that an external service is healthy. Only the checks provide change
evidence, and none is a gate until a named transition is configured or required
to consume its result.

## Evolving the vocabulary

- Change definitions in this document only; instruction files and other
  guidance link here instead of carrying shortened glossary copies.
- Move active guidance, structural checks, templates, and delivery paths in the
  same change set as a definition change.
- Add a compatibility or deprecation note when a replaced term would otherwise
  remain ambiguous during migration.
- Preserve historical records when rewriting them would misstate what happened
  or what people called a mechanism at the time.
- Verify delivery from the reader's side after changing the standing
  instruction contract.

The reusable prompt and expected classification for reader-side trials are in
[`verification-terminology-classification-fixture.md`](verification-terminology-classification-fixture.md).

## See also

- [`definition-of-done.md`](definition-of-done.md) — how repositories declare
  required evidence and current enforcement
- [`shipping-conventions.md`](shipping-conventions.md) — authorization and the
  two standard landing routes
- [`signal-hygiene.md`](signal-hygiene.md) — what makes a result trustworthy
- [`harness-agnostic-repos.md`](harness-agnostic-repos.md) — how the standing
  terminology reaches different agent harnesses
