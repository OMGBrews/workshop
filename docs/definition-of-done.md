# Definition of done

How every repository states the evidence required before work is considered
finished. Read this before authoring or applying a repository's
`docs/work/definition-of-done.md`; the shared terminology is defined in
[`verification-terminology.md`](verification-terminology.md).

**Every repo states its required evidence in one file:
`docs/work/definition-of-done.md`.** Each check names its command, pass
condition, applicability surface, and current enforcement. A repo with no
automated checks says so in one line; that is an answer. A *missing* file is the
only real gap, and it is reported rather than worked around.

The definition of done records current, executable truth. A desired check or
platform rule belongs in a known gap or focused task until it exists and has
been demonstrated. A workflow file proves that automation is configured; it
does not by itself prove a binding landing gate.

**Run the checks whose surface the change actually touches.** Running the rest
is waste, not rigour. Name the checks skipped and why, because afterwards a
silent skip and satisfied evidence look identical. Task briefs never restate
these repository-wide requirements, and the requirements apply regardless of
what a brief says.

**A docs-only change is a lane, not an exemption.** It needs no unrelated build
or test suite, but it does need the repository's prose checks, usually a link
check: moving or deleting a document breaks links in files the diff never
touched. Where the repository carries a `DOCS-ONLY` block, run
`Tools/docs-only-diff.sh <base>` from its Workshop mount. Exit 0 selects the
documented lane; exits 1 and 2 take the normal verification path. No declaration
means no fast lane, and that too is an answer.

**A failed or errored required check is fixed, not weakened** — not with a new
baseline, broadened suppression, or relaxed configuration. Where required
evidence genuinely cannot be obtained, report it as unavailable and stop.

**Landing remains separate from evidence and authorization.** After the
applicable requirements pass, an authorized local session may push directly
where the default branch permits it; a cloud session or protected repository
uses a pull request. Neither a passing check nor a docs-only classification
authorizes a commit, push, pull request, or merge. The full convention is in
[`shipping-conventions.md`](shipping-conventions.md).
