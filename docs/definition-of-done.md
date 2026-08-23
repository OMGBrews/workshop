# Definition of done

What "done" requires, and where each repo says so — read before claiming any change is finished, in any repo.

**Every repo names its gates in one file: `docs/work/definition-of-done.md`** — each gate's command, its pass condition, and the surface it applies to, with nothing beyond what running them takes (that file's authoring rules: [`harness-agnostic-repos.md`](harness-agnostic-repos.md), surface 5). A repo with no automated gates says so in one line; that is an answer. A *missing* file is the only real gap, and it is reported rather than worked around.

**Run the gates whose surface your change actually touches** — running the rest is waste, not rigour. Name the ones you skipped and why, because afterwards a silent skip and a satisfied gate look identical. Task briefs never restate the gates, and the gates apply regardless of what a brief says.

**A docs-only change is a lane, not an exemption.** It needs no build or test suite — never run one to land a typo — but it does need the repo's prose gates, usually a link check: moving or deleting a document breaks links in files the diff never touched. Whether a change qualifies is the declared predicate's call, not the eye's: where the repo's file carries a `DOCS-ONLY` block, ask `bash workshop/Tools/docs-only-diff.sh <base-sha>` — exit 0 takes the docs lane; anything else, cannot-decide included, means run the gates. No declared block, no fast lane, and that too is an answer.

**A red gate is fixed, not weakened** — not with a new baseline, a broadened suppression, or a relaxed config. Where a gate genuinely cannot be satisfied, stop and say so.

Run every gate so its complete output and exit status survive to be read — the trimmed-verdict rule in [`signal-hygiene.md`](signal-hygiene.md), which is also how to read what a gate says.
