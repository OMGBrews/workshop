# Session environment detection

The [canonical detector](templates/cloud-sessions/harness-signals.sh) owns session
location signals for shipping and bootstrap. It distinguishes location from the
separate permission to treat a checkout as disposable; repository shipping policy
still decides how an authorized change lands.

## Command contract

```bash
bash <workshop-mount>/docs/templates/cloud-sessions/harness-signals.sh
```

The command prints exactly one line:

```text
environment=local signal=AGENT_SESSION_ENVIRONMENT
```

`environment` is local, cloud, or unknown. `signal` names the evidence (comma-separated
when several agree), none, invalid input, or conflicting inputs. Exit 0 means a valid
evaluation, including unknown; exit 2 means malformed input or contradictory evidence.
Unknown is not local and cannot select a shipping route. No credentials are inspected
or printed. The detector does not inspect Git remotes, branches, paths, or repository
configuration to infer where the current process runs.

`--environment local` or `--environment cloud` is an explicit user override and
prints `signal=argument`. It wins over automatic signals; it is not evidence that
automatic detection worked. Other arguments fail with usage on stderr.

## Inputs and precedence

| Input | Meaning |
|---|---|
| `AGENT_SESSION_ENVIRONMENT=local\|cloud` | A launcher-provided location assertion, available to every process |
| `CLAUDE_CODE_REMOTE=true` | Claude's managed cloud session; also supplies the existing disposable-checkout capability |
| `AGENT_SESSION_REMOTE=true` | Legacy positive cloud assertion; does not imply a disposable checkout |
| `AGENT_SESSION_EPHEMERAL=true` | Explicit legacy disposable cloud-checkout capability |

Matching assertions agree. A local declaration conflicting with a positive cloud
signal returns unknown and exit 2. Unset signals and legacy false values do not
prove local: the old library generated false merely because it did not recognize
a cloud marker. The new declaration accepts unknown as no assertion. Compatibility
booleans accept true, false, unknown, or unset; other values fail, rather than being
silently treated as false. `AGENT_SESSION_SIGNAL` is output, never an input assertion.

Cloud location alone never enables disposable-checkout actions. Only an explicit
`AGENT_SESSION_EPHEMERAL=true`, or Claude's cloud signal with that capability unset,
enables them. An explicit false capability is respected. Unknown or failed detection
clears the capability. This preserves the existing cloud-bootstrap fast-forward and
token-retry behavior without granting it to every remote session.

## Source compatibility

Bash callers may source the same file. Sourcing emits no output, returns the detector
status, preserves positional arguments, working directory, and shell options, and exports:

- `AGENT_SESSION_ENVIRONMENT` and `AGENT_SESSION_SIGNAL`;
- `AGENT_SESSION_REMOTE`: true for cloud, false for local, unknown otherwise;
- `AGENT_SESSION_EPHEMERAL`: the separately established true/false capability.

Check the source command's status. Do not treat a non-true compatibility value as
proof of local execution. These exports reach descendants only: sourcing a library
inside a SessionStart hook cannot configure a later independent shell process.

## Provisioning and delivery

Local launchers declare `AGENT_SESSION_ENVIRONMENT=local`; cloud launchers declare
cloud. Put the assertion in the process environment, not in a checked-in file that
a cloud clone would also read as local. For a local devcontainer, `containerEnv` is
an appropriate provisioning point; applying a change there requires recreating the
container. Never bake local into a shared image that could run in a cloud session.
A cloud provider's positive marker still conflicts with an incorrectly inherited
local declaration, rather than silently permitting a local shipping route.

Other harnesses use the neutral declaration until they have a supported authoritative
adapter here. A new adapter requires evidence for its marker and behavioral tests;
absence of an unsupported harness's marker is unknown. An explicit override remains
the recovery path for an unprovisioned or contradictory environment.

Bootstrap must detect location before Workshop is initialized. Therefore the kit
seeds a byte-identical copy at `scripts/lib/harness-signals.sh`. It is a checked
copy, not a second authoring source: edit the canonical file, redeploy it, and verify
identity. The bootstrap drift check and cloud declaration validator enforce the
three-file kit; older pins that predate the detector retain their older contract.
HQ, whose Workshop is an independent checkout, verifies its seed in its bootstrap test.

The ship skill always resolves the detector from its own physical Workshop tree,
so an old consumer library cannot break a new skill's protocol. Kit adoption must
include the detector, neutral bootstrap, and vendor wrapper together. Fleet pointer
updates remain separately requested work.

## Verification

`tests/test-session-environment.sh` exercises the command and sourced interfaces,
unknown and invalid inputs, conflicts, explicit overrides, legacy callers, capability
separation, and the ship command resolved through a differently named mount. The
bootstrap and declaration tests exercise missing and drifted deployed copies.
