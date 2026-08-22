# doc-quality × directory

Seven lenses to fan out in parallel against a documentation directory.

Each lens prompt ends with: "Prioritize the top five issues."

Each lens should surface issues visible at the directory scope — how the documents in `<subject>` relate to each other, or how the directory behaves as a whole. Issues that apply equally to a single document viewed in isolation are handled by `doc-quality × file` and should not be reported here. When a document-internal problem distorts the directory's coverage or navigation, report the directory-level implication, not the document-internal detail.

## Lenses

1. Critique `<subject>` as a whole.
2. Evaluate how the documents within `<subject>` are organized, named, and grouped.
3. Evaluate the information architecture of `<subject>` — coverage, navigation, and how its documents relate to each other.
4. Evaluate `<subject>` for internal consistency across its documents, and for consistency with peer documentation directories. Flag body content duplicated across documents (within `<subject>` or against a peer directory) that should have a single home with cross-links — overlapping narration of the same topic in two places drifts apart over time.
5. Read the appropriate style guideline document, then identify style guideline violations within `<subject>`.
6. Identify dead, stale, or orphaned documents within `<subject>`.
7. Identify documentation debt accumulated across `<subject>`.
