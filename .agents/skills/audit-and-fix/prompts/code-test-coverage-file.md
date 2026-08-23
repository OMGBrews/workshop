# code-test-coverage × file

Lens definitions for reviewers auditing test coverage of one source code file.
Load this file after `audit-and-fix` selects a `code-test-coverage` file subject.

Each lens prompt ends with: "Prioritize the top five issues."

The subject is the source file, not a test. Each lens must discover the corresponding test file(s) itself and read them to judge the gap.

Each lens should surface coverage gaps specific to `<subject>` as a single file. Directory-wide coverage patterns — mirrored test organization, integration gaps across modules, or systematic under-coverage of peers — are handled by `code-test-coverage × directory` and should not be reported here.

## Lenses

1. What important behaviors in `<subject>` are untested?
2. Identify error paths and edge cases in `<subject>` that lack test coverage.
3. Identify public API surface in `<subject>` that lacks tests.
4. For tests that do exist covering `<subject>`, do they assert behavior or just structure? Identify what should be improved.
5. Identify parts of `<subject>` that are hard to test — a smell that suggests design changes.
6. Evaluate test coverage of `<subject>` for consistency with how peer modules in the codebase are tested.
7. Identify correctness risks in `<subject>` that a test should have caught.
