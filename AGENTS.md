# AGENTS.md — Workshop

Workshop is the public home for shared agent skills, tooling, and documentation
standards. Read this when contributing here or using Workshop as a submodule.

## Current source of truth

Workshop is the hand-authored source of truth. Contributions follow
[CONTRIBUTING.md](CONTRIBUTING.md), issues follow [SUPPORT.md](SUPPORT.md),
and every change must satisfy the public gates in
[docs/work/definition-of-done.md](docs/work/definition-of-done.md).

## Working in a project that vendors Workshop

- Link Workshop's shared skill roster into a project's `.agents/skills/`;
  `bash workshop/Tools/sync-skill-symlinks.sh .` maintains both the canonical
  surface and the Claude bridge while preserving project-local collisions.
- Read [docs/signal-hygiene.md](docs/signal-hygiene.md) and
  [docs/definition-of-done.md](docs/definition-of-done.md) before claiming a
  check or task complete.
- The repository's own public gates are declared in
  [docs/work/definition-of-done.md](docs/work/definition-of-done.md).
- The superproject that tracks this repository's `main`, and what its pointer owes
  when a change lands here, are declared in
  [docs/work/consumed-by.md](docs/work/consumed-by.md). Every other consumer pins
  this repository, so nothing reaches it until that repo commits a new pointer.

## License

MIT — see [LICENSE](LICENSE).
