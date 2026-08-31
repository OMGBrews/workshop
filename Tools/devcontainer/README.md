# Workshop devcontainer kit

This directory contains the reusable devcontainer build and connection helpers
for Workshop consumers. It deliberately contains no maintainer identity,
private fleet registry, client inventory, or rollout state.

## Consumer contract

Copy `install-packages.sh` during the root build phase, then copy the complete
`build/` directory and run `setup.sh` after switching to the non-root user.
Copy the directory, not selected files: the setup script discovers harnesses
and its scripts resolve siblings beside it. A generic host-side connection
helper is available as `connect.sh`.

Consumers that use a volume workspace may copy `workspace-bootstrap.sh` and
their own project-local lifecycle wrapper. The public kit receives paths and
environment values from that consumer; it does not read HQ records or assume a
particular workspace checkout layout.

## Maintainer boundary

The kit is contributor-neutral: it never sets a Git identity. Private overlays,
fleet templates, and rollout decisions belong to the consuming private control
plane, not to Workshop or this directory.
