# Verification terminology classification fixture

This fixture provides one exact prompt and expected mapping for checking whether
a fresh agent session received the canonical verification terminology. Use it
for reader-side delivery trials; it is observational evidence, not a language-
model conformance gate.

## Exact prompt

Copy the following block without adding terminology hints:

```text
Classify every numbered item using the repository's canonical verification
terminology. For each item, name: (a) what kind of mechanism or evidence it is,
(b) whether it is a gate and, if so, which lifecycle boundary it controls, and
(c) the most precise outcome or enforcement state that can be claimed. Do not
assume facts not stated in the fixture.

1. A developer may install a pre-commit hook that runs `lint`. The hook is not
   installed automatically and `git commit --no-verify` bypasses it.
2. A GitHub Actions workflow contains a `lint` job and a `test` job. Both passed
   on the candidate commit. No repository-rule information is available.
3. GitHub reports that status `verify` is configured as required in a ruleset.
   The ruleset is in evaluate mode.
4. Status `verify` is required by an active branch rule. An authoritative rule
   query confirms that it applies to `main`, and the actor has no bypass.
5. A path classifier selects the documentation lane. The lane's link check did
   not run because a dependency expression was misspelled.
6. A generator rewrites `docs/index.md`; a separate comparison reports that the
   committed file matches freshly generated output.
7. A scheduled monitor reports that the production API is healthy. No release,
   deployment, or landing process consumes the monitor result.
8. The definition of done says `make check` must pass before an authorized local
   direct push. Participants follow the rule, but GitHub does not block pushes.
9. CI builds artifact digest `sha256:abc` once. A release declares that digest,
   publication puts it in a registry, promotion marks the same digest eligible
   for production, and deployment installs it. A health check then passes.
10. A required device test is not relevant to a documentation-only release;
    policy explicitly classifies it as inapplicable. A different required test
    is skipped unexpectedly because its runner label matches no machine.
```

## Expected mapping

Equivalent wording is acceptable when it preserves every distinction below.

| # | Expected classification |
|---|---|
| 1 | A pre-commit hook providing commit-time feedback and, when invoked normally in that clone, a bypassable local commit gate. It is not fleet-wide landing enforcement. No execution outcome is stated. |
| 2 | A CI workflow containing two checks or jobs whose results passed. With no rule evidence, neither the workflow nor the results can be called a landing gate or required status. Enforcement is unconfirmed. |
| 3 | A configured required status check, not a confirmed binding landing requirement. Evaluate mode does not block landing. |
| 4 | A confirmed binding landing requirement participating in the landing gate for `main`, for the stated actor and route. |
| 5 | The classifier selected applicability; it did not provide passing evidence. The link check was skipped unexpectedly, so required evidence is missing rather than passed or not applicable. |
| 6 | A generator produced output; a separate freshness check passed. The generator itself is not a check or gate. |
| 7 | A monitor with a healthy observation. It is neither change verification nor a gate because no named transition consumes it. |
| 8 | A procedural landing requirement using a passed local verification suite plus authorization. The landing gate is procedural, not platform-enforced. |
| 9 | Separate build, release, publish, promote, deploy, and post-deployment-verification actions. The same immutable artifact was promoted; the health check passed after deployment. No gate can be claimed without stated requirements or controls. |
| 10 | The device-test requirement is not applicable by explicit policy. The runner-starved test was skipped unexpectedly; it did not pass and its evidence is unavailable until it can run. |

## Recording a trial

Record the repository commit, Workshop commit, harness and version, exact prompt,
faithful response, comparison with this mapping, and any limitation. A model
response is evidence that delivery worked in that observed session. The durable
control remains the canonical document plus the required instruction links and
imports.

## See also

- [`verification-terminology.md`](verification-terminology.md) — canonical
  definitions used by this fixture
- [`harness-agnostic-repos.md`](harness-agnostic-repos.md) — instruction
  delivery contract
