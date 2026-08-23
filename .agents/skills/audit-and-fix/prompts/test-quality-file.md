# test-quality × file

Lens definitions for reviewers auditing one test file. Load this file after
`audit-and-fix` selects a `test-quality` file subject.

Each lens prompt ends with: "Prioritize the top five issues."

Each lens should surface issues visible within `<subject>` as a single test file. Directory-wide patterns — fixture architecture, test organization across the directory, or cross-file consistency — are handled by `test-quality × directory` and should not be reported here.

## Lenses

1. Critique `<subject>`.
2. Identify weak or missing assertions within `<subject>`.
3. Identify mocking problems within `<subject>`.
4. Identify flakiness risks within `<subject>`.
5. Identify dead, redundant, or trivially-passing tests within `<subject>`.
6. Read the test style and convention sources at `<style-guide>`, then identify violations within `<subject>`.
7. Do the tests in `<subject>` exercise meaningful behavior, or merely structure? If not, identify what should be improved.
