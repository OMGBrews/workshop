# code-quality × file

Lens definitions for reviewers auditing one code file. Load this file after
`audit-and-fix` selects a `code-quality` file subject.

Each lens prompt ends with: "Prioritize the top five issues."

Each lens should surface issues visible within `<subject>` as a single file. Directory-wide patterns — organization, architecture, or cross-file consistency — are handled by `code-quality × directory` and should not be reported here.

## Lenses

1. Critique `<subject>`.
2. Identify dead code within `<subject>`.
3. Read the style and convention sources at `<style-guide>`, then identify violations within `<subject>`.
4. Identify technical debt within `<subject>`.
5. Does the code within `<subject>` follow industry-standard best practices throughout? If not, identify what should be improved.
6. Evaluate `<subject>` for consistency, both within the file and with its peers.
7. Identify correctness bugs within `<subject>`.
