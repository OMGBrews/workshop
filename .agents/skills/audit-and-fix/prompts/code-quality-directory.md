# code-quality × directory

Seven lenses to fan out in parallel against a code directory.

Each lens prompt ends with: "Prioritize the top five issues."

Each lens should surface issues visible at the directory scope — how the directory's files relate to each other, or how the directory behaves as a whole. Issues that apply equally to a single file viewed in isolation are handled by `code-quality × file` and should not be reported here. When a file-internal problem (e.g., a bloated module) distorts the directory's layout, report the directory-level implication, not the file-internal detail.

## Lenses

1. Critique `<subject>` as a whole.
2. Evaluate how files and subdirectories within `<subject>` are organized, named, and grouped.
3. Evaluate the architecture of `<subject>` — the boundaries between its pieces, how they fit together, and how they collaborate.
4. Evaluate `<subject>` for internal consistency across its files and subdirectories, and for consistency with its peers.
5. Read the appropriate style guideline document, then identify style guideline violations within `<subject>`.
6. Identify dead code, unused modules, or orphaned files within `<subject>`.
7. Identify technical debt accumulated across `<subject>`.
