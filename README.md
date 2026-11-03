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

From a project root with an `AGENTS.md`, mount Workshop as a pinned submodule,
usually at `workshop/`, then link its shared skills and standing rules:

```bash
git submodule add https://github.com/OMGBrewmaster/workshop.git workshop
mkdir -p .agents
bash workshop/Tools/sync-skill-symlinks.sh .
bash workshop/Tools/sync-rules-symlinks.sh .
```

The skill sync command creates one link per shared skill on `.agents/skills/` and
the Claude-specific bridge beside it. Linking the complete roster preserves
dependencies between skill families, including `audit-next` and `audit-done`'s
dependency on the engine inside `audit-and-fix`. The tool discovers the actual
mount name, so `workshop/` is a convention rather than a requirement. The rules
sync command creates the three standing-rule links in `.claude/rules/`. Also
link those documents from the project's `AGENTS.md`, as described in
[the harness-agnostic setup guide](docs/harness-agnostic-repos.md). Re-run both
commands after a Workshop pointer bump and commit both generated surfaces with
the pointer.

Projects that consume Workshop's devcontainer build kit can give Claude Code,
Codex, and Oh My Pi shared prompt-entry behavior. See
[the devcontainer harness keybindings guide](docs/devcontainer-harness-keybindings.md)
for the image-build path, the live-apply command, and the host-terminal prerequisite.

## Checks and releases

Run `make check` from a standalone clone to execute Workshop's complete public
verification suite. It requires Bash, Git, Python 3.11+, jq, ShellCheck, and
Zsh; the launcher tests exercise real Bash and Zsh startup behavior.
The Markdown link check validates section fragments by default using the
[bundled parser](Tools/vendor/README.md); no Python package installation or
network access is needed. After adopting a new Workshop pin, run
`bash workshop/Tools/check-markdown-links.sh .` in the consumer. A
`missing Markdown anchor: source -> target#fragment` diagnostic means the
heading or explicit anchor is absent: repair the link or restore the intended
anchor and rerun the check. Exit 1 means broken links; exit 2 means incomplete
checking or a parser/runtime error. Named skips identify unchecked targets.

GitHub Actions runs that same command for pushes, pull requests, and
tags. Maintainers create milestone tags and GitHub Releases manually after the
check passes; tags are immutable and identify the exact release commit. There
is no promised release cadence or semantic-versioning compatibility contract.

See [CHANGELOG.md](CHANGELOG.md) for release notes and
[docs/work/definition-of-done.md](docs/work/definition-of-done.md) for the
local evidence contract. The shared meanings of checks, requirements, gates,
release, and deployment are in
[docs/verification-terminology.md](docs/verification-terminology.md).

## Cutover record

[docs/source-of-truth-cutover.md](docs/source-of-truth-cutover.md) records the
transition from the final generated payload to the public source of truth.

## License

MIT — see [LICENSE](LICENSE).
