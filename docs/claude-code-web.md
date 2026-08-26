# Claude Code Web environment declarations

This standard defines the repository-owned desired-state record for Claude Code
Web environments. Project maintainers and Workshop tools use it to select,
reproduce, and audit a project's Web environment without relying on a private
fleet inventory.

## Required project document

Every project repository in the fleet carries
`docs/work/claude-code-web.md`. The file states whether the repository is
configured for Claude Code Web, is not yet configured, or cannot support Web
sessions. Keeping an explicit negative state distinguishes a reviewed
repository from a missing rollout.

The public `OMGBrews/workshop` repository is the one host exception: it
distributes this standard and its tool, but it is mounted by the private
`OMGBrews/workshop-dev` maintainer wrapper and is not selected as a Web session's
primary repository. The wrapper carries the declaration. Workshop therefore
intentionally omits its own `docs/work/claude-code-web.md`; the validator's
missing-declaration result prevents anyone from treating the public host as a
configured primary by accident.

The document is the canonical, Git-versioned declaration of desired state. The
live Claude environment is deployed external state; the document does not prove
that the live state exists or conforms. A project may explain its choices in
ordinary Markdown, but it must contain exactly one machine-readable block:

````markdown
<!-- WORKSHOP-CLOUD-SESSION:BEGIN -->
```json
{
  "version": 1,
  "availability": "configured",
  "primaryRepository": "example/project",
  "additionalRepositories": [],
  "environment": {
    "name": "project",
    "id": "env_0123456789abcdef",
    "network": {
      "access": "custom",
      "includeCommonPackageManagers": true,
      "allowedDomains": [
        "api.example.com"
      ]
    },
    "environmentVariables": [
      {
        "name": "API_BASE_URL",
        "source": "literal",
        "value": "https://api.example.com"
      },
      {
        "name": "API_TOKEN",
        "source": "secret",
        "required": true
      }
    ],
    "setupScript": [
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      "bash scripts/agent/cloud-setup.sh"
    ]
  }
}
```
<!-- WORKSHOP-CLOUD-SESSION:END -->
````

The sentinels and JSON fence are stable interfaces. Tools parse only that block,
never headings or explanatory prose.

## Version 1 schema

Every declaration has these fields:

| Field | Requirement |
|---|---|
| `version` | Integer `1`. |
| `availability` | `configured`, `not-configured`, or `unsupported`. |
| `primaryRepository` | The normalized `owner/repo` selected as the Web session's primary repository. |
| `additionalRepositories` | Sorted, unique `owner/repo` values that every session must attach. Task-specific, shipping-only, and prior-art repositories do not belong here. |

A `configured` declaration also has an `environment` object and no `reason`.
The environment contains every observable setting:

| Field | Requirement |
|---|---|
| `name` | Human-facing environment name in Claude Code Web. |
| `id` | Claude environment identifier beginning with `env_`. |
| `network.access` | `none`, `trusted`, `full`, or `custom`. |
| `network.includeCommonPackageManagers` | Boolean state of the common package-manager domain option. |
| `network.allowedDomains` | Sorted, unique DNS names, optionally beginning with `*.`. Entries are allowed only with `custom` access. |
| `environmentVariables` | Variables sorted by name, using one of the safe forms below. Names are unique. |
| `setupScript` | Exact script as an array of lines. An empty array declares a blank script. |

A non-secret variable is explicit and versioned:

```json
{
  "name": "FEATURE_MODE",
  "source": "literal",
  "value": "enabled"
}
```

Names containing `KEY`, `TOKEN`, `PASSWORD`, `PASSWD`, `SECRET`,
`CREDENTIAL`, or `CREDENTIALS`, and names ending in `_B64` or `_BASE64`, are
presumed secret-bearing. They cannot use `source: "literal"` unless a known
public value is explicitly justified:

```json
{
  "name": "PUBLIC_API_KEY",
  "source": "literal",
  "value": "public-browser-identifier",
  "nonSecretJustification": "The provider publishes this browser identifier and does not authenticate requests with it."
}
```

Do not use the exception merely because a credential is development-only or
low-privilege. The field exists for values whose names resemble credentials but
whose documented semantics are genuinely public.

A secret declaration records only its name and whether it is required:

```json
{
  "name": "SERVICE_API_KEY",
  "source": "secret",
  "required": true
}
```

Secret entries never have a `value` field. Placeholder values such as
`<secret>` are not a substitute: a deployment tool could mistake one for a
literal. Secret values remain in the account's protected configuration and are
never committed, rendered, logged, or compared.

Local validation proves that the declaration uses the secret-safe structure and
catches obvious secret-bearing names declared as literals. It cannot prove that
someone did not paste an opaque secret into an innocently named literal field;
review and provider-side secret scanning remain necessary evidence for that
content-level claim.

`not-configured` and `unsupported` declarations have a non-empty `reason` and
no `environment` object:

```json
{
  "version": 1,
  "availability": "not-configured",
  "primaryRepository": "example/project",
  "additionalRepositories": [],
  "reason": "No cloud environment has been provisioned for this project."
}
```

Use `not-configured` when Web support is possible but not provisioned. Use
`unsupported` when a known platform or project constraint prevents the work.

## Claude settings projection

A configured repository also declares the same environment ID at
`.claude/settings.json` → `remote.defaultEnvironmentId`. The Workshop document
is canonical; Claude settings are its harness-specific projection. The validator
rejects a missing or mismatched projection. A `not-configured` or `unsupported`
repository must not retain a default environment ID because that would
contradict its declared state.

`primaryRepository` must match the checkout's GitHub `origin`. Validation takes
a repository root, not an arbitrary subdirectory, so a declaration cannot be
silently checked against the wrong project.

## Tooling

Run the shared tool from any checkout of Workshop:

```bash
python3 workshop/Tools/claude-code-web.py validate .
python3 workshop/Tools/claude-code-web.py show .
python3 workshop/Tools/claude-code-web.py show . --json
python3 workshop/Tools/claude-code-web.py render-setup .
```

Use the actual Workshop mount name when it differs from `workshop`. From a
standalone Workshop source checkout, invoke `Tools/claude-code-web.py` and pass
the target project path; the public Workshop host itself intentionally has no
declaration. `validate` checks the declaration and settings projection. `show`
prints a safe launch summary without secret values; `show --json` emits stable,
normalized JSON for fleet aggregation. `render-setup` emits the exact configured
setup script and refuses non-configured states. Validation is local evidence
only; it does not claim that the external environment exists or matches.

Future account-aware tooling should describe external state as **observed** and
compare it with this **declared** state. It may call the result **conformant**
only when every observable setting matches, and must report secret presence as
unconfirmed where Claude does not expose it.

Agents answer launch-configuration questions through the shared
`claude-web-session` skill. The skill delegates parsing to this tool, preserves
the declaration's negative states, and treats live environment changes and Web
session launches as separately authorized external actions.

## Ownership and fleet inventories

Dedicated environments are owned by their project declaration. Every consumer
of a shared environment still carries its complete desired state so its checkout
remains self-describing. Fleet validation groups declarations by environment ID
and rejects divergent environment objects; that mechanical consistency check is
what makes the necessary duplication safe. Fleet inventories are generated from
project declarations and are not hand-maintained lists of names or IDs.

Task-specific attachments remain task input. Parent repositories needed only to
ship a submodule pointer remain declared in `docs/work/consumed-by.md`; child
composition remains declared in `.gitmodules`.

## See also

- [Definition of done](definition-of-done.md) — evidence required before work is complete
- [Secrets in workflows](secrets-in-workflows.md) — secret-handling boundaries
- [Verification terminology](verification-terminology.md) — language for declared and observed evidence
