# readme-quality × directory

Lens definitions for reviewers auditing a directory's `README.md`. Load this
file after `audit-and-fix` selects a `readme-quality` directory subject; the
audited artifact is `<subject>/README.md`.

Each lens prompt ends with: "Prioritize the top five issues."

The audited artifact is the single file `<subject>/README.md`. The surrounding directory `<subject>` and its sibling directories serve as ground truth for factual claims and as the reference for consistency. Each lens should evaluate the README against that ground truth and against peer READMEs.

## Lenses

1. Critique `<subject>/README.md`.
2. Identify dead or stale content within `<subject>/README.md` — claims that no longer match the current contents of `<subject>`.
3. Read the README and documentation style sources at `<style-guide>`, then identify violations within `<subject>/README.md`.
4. Locate the tests that exercise `<subject>` (search `tests/` and any colocated `*.test.*` files for files referencing this module). Identify behaviors the tests verify that `<subject>/README.md` doesn't mention, claims in the README that the tests would invalidate, and examples in the README that wouldn't survive contact with the test suite. If `<subject>` has no tests, say so plainly and stop — don't invent filler.
5. Does `<subject>/README.md` serve its purpose of orienting readers to `<subject>`? If not, identify what should be improved.
6. Evaluate `<subject>/README.md` for consistency with peer READMEs in sibling directories.
7. Identify factual inaccuracies in `<subject>/README.md` — claims that contradict the current contents of `<subject>`.
8. Grep the codebase for callers of `<subject>`'s public symbols. Identify behavior current callers depend on that `<subject>/README.md` doesn't document, and guarantees in the README that no caller actually exercises (i.e., over-promises with no consumer). Cite specific caller files and lines.
