# audit-and-fix prompts

Lens prompt files consumed by `/audit-and-fix`. One file per `<audit-type>-<kind>` combination. The parent [`SKILL.md`](../SKILL.md) picks the right file based on the Step 1 subject.

## Layout

| File | Audit type | Kind |
|------|------------|------|
| [code-quality-file.md](./code-quality-file.md) | `code-quality` | file |
| [code-quality-directory.md](./code-quality-directory.md) | `code-quality` | directory |
| [doc-quality-file.md](./doc-quality-file.md) | `doc-quality` | file |
| [doc-quality-directory.md](./doc-quality-directory.md) | `doc-quality` | directory |
| [readme-quality-directory.md](./readme-quality-directory.md) | `readme-quality` | directory |
| [test-quality-file.md](./test-quality-file.md) | `test-quality` | file |
| [test-quality-directory.md](./test-quality-directory.md) | `test-quality` | directory |
| [code-test-coverage-file.md](./code-test-coverage-file.md) | `code-test-coverage` | file |
| [code-test-coverage-directory.md](./code-test-coverage-directory.md) | `code-test-coverage` | directory |

`readme-quality` has no `file` variant — the tracker only configures it against directories, and the README under audit is always `<subject>/README.md`.

The `code-test-coverage` subject is a *source* path, not a test path; lens prompts in those files instruct each subagent to discover and read the corresponding test(s) itself so it can judge the coverage gap.

## Conventions

Each file contains an optional scope-framing paragraph and seven lens prompts to fan out in parallel. The lenses are **deliberately vague** — write open-ended questions, not checklists. The orchestrator (SKILL.md Step 2) adds the operational wrapping (subject path, closing "Prioritize the top five issues.", anti-filler clause).

### Scope-framing paragraph

Optionally place a single paragraph between the preamble and the `## Lenses` heading. Use it to set scope for all seven lenses: what kind of issues this audit should surface, which sibling audit handles out-of-scope findings, and (if useful) one sentence on how to reframe adjacent-scope findings rather than suppress them. The orchestrator includes this paragraph in every subagent prompt.

A scope paragraph is especially valuable for `directory` variants, where lens agents otherwise default to file-internal findings that duplicate the sibling `file` audit.

### Lens wording

- Keep each lens to a single sentence or question.
- Do not enumerate examples ("off-by-one, null handling, ...") — the examples narrow interpretation and silence lenses the list didn't anticipate.
- Use `<subject>` as the placeholder for the target path.
- Mirror wording across combinations where scope allows, but let scope drive legitimate divergence. A `file` variant should use file-scope lenses (single-artifact concerns); a `directory` variant should use directory-scale lenses (cross-file patterns, organization, architecture). Don't clone one into the other.

### Style-guideline lens

When a prompt includes a style-guideline lens, phrase it as: `Read the appropriate style guideline document, then identify style guideline violations within <subject>.` This directs only the one subagent to consult the style guide, rather than every lens duplicating that effort.

## Adding a new combination

1. Create `prompts/<audit-type>-<kind>.md` with the seven lenses.
2. Add a row to the table in [`SKILL.md`](../SKILL.md) Step 2.
3. Update each adopting repo's audit config (`docs/work/audits/config.toml`) if the combination needs tracker support. The shipped prompt set is the closed vocabulary of audit types: a config naming a type/kind with no prompt file here is rejected. Adding a type is a Workshop contribution (PR + pin bump), never a per-repo prompt fork.

## See also

- [../SKILL.md](../SKILL.md) — orchestration logic
- [../../audit-next/SKILL.md](../../audit-next/SKILL.md) — picks paths without the full audit loop
- [../../audit-done/SKILL.md](../../audit-done/SKILL.md) — records completion without the full audit loop
