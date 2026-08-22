# doc-quality × file

Seven lenses to fan out in parallel against a documentation file.

Each lens prompt ends with: "Prioritize the top five issues."

Each lens is file-scoped: findings must be about `<subject>` itself, even when checking `<subject>` against the code, referenced standards, or sibling documents. Directory-wide patterns — overall navigation coherence across a tree, coverage gaps across siblings — are handled by `doc-quality × directory` and should not be reported here.

## Lenses

1. Critique `<subject>`.
2. Read the appropriate style guideline document, then identify style guideline violations within `<subject>`.
3. Verify that every command, code snippet, and procedure in `<subject>` actually works as written. Mentally (or actually) execute each one against the current codebase and configuration, and flag anything that would fail, error, produce unexpected output, or leave the reader stuck.
4. Identify factual inaccuracies and contradictions involving `<subject>`. For every claim — file paths, symbol names, default values, version requirements, behaviors, architecture, referenced standards, external specs — verify against the authoritative source (current code, configuration, sibling documents) and flag mismatches. A finding is in scope only if `<subject>` makes a claim; gaps or errors in sibling documents that don't touch `<subject>` are out of scope.
5. Identify missing information within `<subject>` — things a reader (human or AI agent) would reasonably expect to find but don't.
6. Identify content in `<subject>` that has become misleading over time — most commonly, tables, lists, and descriptions that were complete or accurate when written but have silently fallen out of date as the project evolved (new entries not added, references to removed or renamed features, superseded plans). The distinguishing signal is drift: the claim was true in an earlier version and hasn't tracked reality since. Outright-wrong claims that were never accurate belong to lens 4, not here. If several stale references trace to one root cause, report them as one finding, not several.
7. Evaluate `<subject>` against its dual audience: does it correctly educate a curious human, and does it direct an AI agent to the right next-hop information via progressive disclosure (clear top-level summary, outbound links to depth, appropriate altitude)?
