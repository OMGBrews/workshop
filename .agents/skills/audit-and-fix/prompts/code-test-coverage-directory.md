# code-test-coverage × directory

Seven lenses to fan out in parallel against a source directory, asking whether the code within is adequately tested.

Each lens prompt ends with: "Prioritize the top five issues."

The subject is a source directory, not a test directory. Each lens must locate the corresponding test directory and files itself and read them to judge the gap.

Each lens should surface coverage gaps visible at the directory scope — how coverage is distributed across `<subject>`, or integration gaps between its modules. Issues that apply equally to a single file viewed in isolation are handled by `code-test-coverage × file` and should not be reported here. When a file-internal coverage gap indicates a directory-scale pattern, report the directory-level implication.

## Lenses

1. Critique test coverage of `<subject>` as a whole.
2. Identify behaviors spanning multiple files in `<subject>` that lack integration coverage.
3. Evaluate how thoroughly the public API surface of `<subject>` is tested across all its modules.
4. Evaluate how the test organization for `<subject>` mirrors its source organization.
5. Identify systematic coverage gaps — modules or features within `<subject>` that are under-tested relative to peers.
6. Identify design or coupling patterns across `<subject>` that make the directory hard to test.
7. Identify correctness risks across `<subject>` that integration or cross-module tests should have caught.
