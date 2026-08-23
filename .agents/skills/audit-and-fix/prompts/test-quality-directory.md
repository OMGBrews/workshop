# test-quality × directory

Lens definitions for reviewers auditing one directory of tests. Load this file
after `audit-and-fix` selects a `test-quality` directory subject.

Each lens prompt ends with: "Prioritize the top five issues."

Each lens should surface issues visible at the directory scope — how the test files in `<subject>` relate to each other, or how the directory behaves as a whole. Issues that apply equally to a single test file viewed in isolation are handled by `test-quality × file` and should not be reported here. When a file-internal problem distorts the directory's fixture layout or test organization, report the directory-level implication, not the file-internal detail.

## Lenses

1. Critique `<subject>` as a whole.
2. Evaluate how the test files within `<subject>` are organized, named, and grouped.
3. Evaluate how fixtures, helpers, and shared utilities are architected across `<subject>`.
4. Evaluate `<subject>` for internal consistency across its test files, and for consistency with peer test directories.
5. Read the test style and convention sources at `<style-guide>`, then identify violations within `<subject>`.
6. Identify dead, redundant, or orphaned tests and fixtures within `<subject>`.
7. Identify test-quality debt accumulated across `<subject>`.
