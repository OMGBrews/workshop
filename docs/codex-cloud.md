# Codex cloud declarations

This standard declares a repository's manual Codex cloud setup and readiness
evidence. It supports published reusable environments and agent-invoked startup;
CLI dispatch and automatic startup are not part of the demonstrated route.

## Ownership and identity

Consumers own `docs/work/codex-cloud.md`, setup/start scripts, capabilities and
live trial evidence. Workshop owns this schema and `Tools/codex-cloud.py`.
Keep one JSON block between the sentinels below. The validator checks strict keys,
duplicate keys, checkout identity, referenced files and field types. It neither
contacts the platform nor publishes configuration, launches tasks, grants access,
or establishes that recorded evidence is true.

Use the stable `source_config_id` as `configId`, and the published
`source_config_version_id` as `versionId`. Treat both as opaque nonempty strings;
there is no invented prefix requirement. Runtime environment and thread IDs belong
in the evidence, never in place of configuration identity. Matching environment
names alone does not establish matching configurations. A draft is not a published
version; reconcile saved fields, publication and the fresh task's source version.

## Configured declaration

The example uses placeholder identities; replace them with observations. Referenced
files must exist. Commands are argv arrays executed through bash, never evaluated
by the declaration tool. Paths must stay inside the repository; checkoutPath is
the observed absolute path in the prepared environment, not a local checkout path.

<!-- WORKSHOP-CODEX-CLOUD:BEGIN -->
```json
{
  "version": 1,
  "availability": "configured",
  "primaryRepository": "example/project",
  "additionalRepositories": [],
  "environment": {
    "name": "project",
    "configId": "observed-stable-configuration-id",
    "versionId": "observed-published-version-id",
    "checkoutPath": "/workspace/project",
    "installScript": "scripts/agent/cloud-setup.sh",
    "startCommand": ["bash", "scripts/agent/codex-cloud.sh", "start", "{source}"],
    "commandPrefix": ["bash", "scripts/agent/codex-cloud.sh", "run"],
    "network": {
      "access": "restricted",
      "includePackageManagers": true,
      "allowedDomains": []
    },
    "bindings": []
  },
  "readiness": {"state": "unverified"}
}
```
<!-- WORKSHOP-CODEX-CLOUD:END -->

Required top-level fields are version (integer 1), availability, primaryRepository
and additionalRepositories (sorted unique owner/repo identities excluding primary).
Configured requires exactly environment and readiness, and forbids reason. All
example environment fields are required. Network access is restricted or full;
includePackageManagers is boolean and allowedDomains is a sorted unique list of
bare DNS names (wildcard subdomains allowed). These describe desired public-network
settings, not observed connectivity. Additional repositories are declarations of
required access, not promises they were cloned or initialized.

Bindings are sorted by unique name and carry no values. Each entry has `name`,
`kind` (`variable` or `network-secret`) and boolean `required`. A network-secret
also requires nonempty sorted `allowedDomains`; a variable forbids that field.
Configure values through environment settings or the platform vault, never git.
Network permission and credentials are separate. Do not echo resolved credentials.
This standard deliberately does not synchronize secret values or local CLI auth.

`startCommand` must contain exactly one standalone `{source}` argument, replaced
with the intended full commit SHA. Other placeholders are forbidden.
`commandPrefix` has no placeholders and is prepended to each subsequent command.
Both begin with bash and an existing repository-relative script. installScript
also names an existing repository-relative file; render-setup invokes it from the
configured checkout. Rendering quotes paths and arguments but does not run them.

`readiness` is either `{"state":"unverified"}` or
`{"state":"recorded","evidence":"docs/evidence/codex-trial.md"}`. The latter
requires an existing repository-relative evidence file. It means an evidence record
exists, not that a validator verified a live environment. Configured is never a
synonym for ready. Do not copy evidence between repositories or configuration versions.

## Negative states

Use this shape for reviewed repositories without a usable configuration:

```json
{
  "version": 1,
  "availability": "not-configured",
  "primaryRepository": "example/project",
  "additionalRepositories": [],
  "reason": "No published environment has been prepared."
}
```

`unsupported` uses the same shape with a concrete reason. Both forbid environment
and readiness. A missing or malformed declaration is an error, not a negative state.

## Commands

From the consumer root, resolve the tool from its physical Workshop mount:

```bash
python3 workshop/Tools/codex-cloud.py validate .
python3 workshop/Tools/codex-cloud.py show . --json
python3 workshop/Tools/codex-cloud.py render-setup .
python3 workshop/Tools/codex-cloud.py render-start . --source <full-source-sha>
```

`validate` exits 0 for local conformance, 1 for invalid declarations/files.
Command-line usage errors exit 2. `show` emits a summary or normalized JSON.
Render commands refuse negative availability. Review rendered setup and saved
settings, publish through the platform, and test in a fresh task. Rendering is
not evidence that any command ran or settings were saved.

## Startup contract

AGENTS.md must route Codex cloud sessions to tracked startup instructions. Do not
rely on delivery of a platform start skill or retained proposal files. The manual
launch prompt names an exact source revision: record initial source, safely select
that revision without discarding work, restore only clean submodules to recorded
pins, and reread AGENTS.md. Stop if that cannot be done. A stale snapshot must not
pass by substituting its own HEAD for the requested SHA.

The repository start command must verify source identity, initialize missing
Workshop, preserve initialized or dirty work, inspect report-only bootstrap output,
and positively verify its required dependencies. Each command prefix must activate
its own shell and preserve arguments and exit status. Provision pinned tools from
the repository setup entry point; isolate Claude hook/auth side effects. No
hardcoded engine version belongs in this shared standard. Keep cached work safe:
explicit cloud location and ephemeral permission are separate assertions under
[the detector contract](session-environment.md).

For private assets use the platform's existing HTTPS authentication and direct
[Git LFS hydration](cloud-git-lfs.md). Do not invoke Claude's session or credential
fallback path. Require a positive census, zero pointers and current index. Failure
means rendering evidence is unavailable, never skipped or passed. Hydration is
not proof of new LFS upload access. Retained dependencies are not proof of startup
execution. Per-shell activation is not inherited from an earlier tool call.

## Capability authority

Outside the JSON block, each configured declaration must include a prose section
`What a cloud session can do` and a corresponding list of unavailable or unknown
capabilities. Name executable checks, toolchain requirements, private assets,
hardware constraints and any further authoritative repository documents. The
manual workflow reads these sections from the selected source revision to classify
acceptance criteria. Schema validation does not verify prose or capabilities;
missing or unsupported evidence must hold affected implementation tasks.

## Live evidence and shipping

Record source/Workshop SHAs, stable configuration/version IDs, observed runtime and
thread identity, initial state, agent-invoked actions versus automatic actions,
bootstrap output/status, LFS census, dependency probes, required check results and
limitations. Evidence should identify its provenance and retained raw logs without
claiming inaccessible logs were independently reviewed. A fresh task must follow
tracked instructions without proposal-file recovery. Run a real implementation
through owner close-out and `ship`, record the returned PR and CI, and distinguish
publication from landing. Reverify when source, configuration or dependencies change.

Use the repository cloud ship policy. If subscription/timer tools are unavailable,
an explicitly agreed policy may use direct CI reads and owner-driven resume;
never silently substitute a scheduler or infer merge authority. The shared
[cloud workflow](../.agents/skills/problem-plan-cloud/cloud-dispatch.md) reuses
record eligibility, overlap and capability checks while preparing manual prompts.
Prepared prompts are not launched sessions; missing in-flight visibility is unknown.
