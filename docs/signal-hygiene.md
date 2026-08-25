# Signal hygiene

How to know a step actually happened — read before trusting any check, script, or "done" claim, in every repo. Exact mechanics, idioms, and the incidents behind each rule: [`signal-hygiene-reference.md`](signal-hygiene-reference.md).

**A result is evidence only if failure would have looked different.** Ask of any signal — above all one you built — what it would show if the step had failed or done nothing. If that matches what you are looking at, it is decoration, not verification; assert a positive property of the artifact you meant to produce instead. The recurring shapes:

- **A trimmed verdict.** The command's own exit status and complete output are the verification; nothing else is. Verbose output tempts wrappers — piping through a trimmer, quiet flags, discarded stderr, a backgrounded run — and every wrapper reports *its own* status, so a red run announces itself green and the text explaining why is discarded. Separate capture from reading: land the full output *and* the exit status together in an artifact, then read as small a slice of the artifact as you like. Trimming a file after the verdict is safe; trimming the stream that carries the verdict is the defect.

- **Trusted silence.** "Nothing found" is what a clean pass prints — and also what prints when the check ran in the wrong directory, the search tool skipped ignored paths, the pathspec is untracked, or the ref it read is a stale snapshot. A negative result is a lower bound, not a total, until you confirm the check could have seen a positive.

- **A never-run deliverable.** If you never executed it, it is a draft — say so. In an environment that cannot run it, the first real run is part of authoring, not verification afterwards.

Git's version of both: remote-tracking refs like `origin/main` are snapshots from your last fetch, so fetch before sizing any decision off them. And `HEAD == origin/main` is equality, not containment — true when your commit landed *and* when a rebase destroyed it. Read a push's own output; to prove a remote holds a commit, fetch, then test ancestry.

The prose sibling: a claim that changes what someone spends or configures needs a source — "it makes the pieces fit" is not one.
