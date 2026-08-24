# Workshop

Workshop is the public distribution of shared agent skills, tooling, and
documentation standards. It is the hand-authored source of truth and is ready
to be used and maintained as a standalone repository.

## Contributing

Open a focused pull request after running `make check` from a standalone clone.
[CONTRIBUTING.md](CONTRIBUTING.md) describes the workflow, and
[SUPPORT.md](SUPPORT.md) explains where to ask for help or report a security
issue.

## Use in another project

Mount Workshop as a pinned submodule, usually at `workshop/`, then link its
shared skill roster:

```bash
git submodule add https://github.com/OMGBrewmaster/workshop.git workshop
bash workshop/Tools/sync-skill-symlinks.sh .
```

The sync command creates one link per shared skill on `.agents/skills/` and
the Claude-specific bridge beside it. Linking the complete roster preserves
dependencies between skill families, including `audit-next` and `audit-done`'s
dependency on the engine inside `audit-and-fix`. The tool discovers the actual
mount name, so `workshop/` is a convention rather than a requirement.

Projects that consume Workshop's devcontainer build kit can give Claude Code,
Codex, and Oh My Pi shared prompt-entry behavior. See
[the devcontainer harness keybindings guide](docs/devcontainer-harness-keybindings.md)
for the image-build path, the live-apply command, and the host-terminal prerequisite.

## Checks and releases

Run `make check` from a standalone clone to execute Workshop's complete public
gate set. GitHub Actions runs that same command for pushes, pull requests, and
tags. Maintainers create milestone tags and GitHub Releases manually after the
check passes; tags are immutable and identify the exact release commit. There
is no promised release cadence or semantic-versioning compatibility contract.

See [CHANGELOG.md](CHANGELOG.md) for release notes and
[docs/work/definition-of-done.md](docs/work/definition-of-done.md) for the
local check contract.

## Cutover record

[docs/source-of-truth-cutover.md](docs/source-of-truth-cutover.md) records the
transition from the final generated payload to the public source of truth.

## License

MIT — see [LICENSE](LICENSE).
