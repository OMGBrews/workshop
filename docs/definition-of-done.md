# Definition of done

What "done" requires, and where each repo says so. Read this before claiming any change
is finished — in any repo, whether you are a human, an interactive session, or an
autonomous worker.

## The rule

**Every repo names its gates in one file: `docs/work/definition-of-done.md`**
It lists each gate's command, its pass condition, and the surface it applies to. A repo
with no automated gates says so in one line; that is an answer. A *missing* file is the
only real gap, and it is the one thing to report rather than work around.

**And that file's scope is the gates, nothing more.** It carries the gates table, the
`DOCS-ONLY` block where the repo declares one, and the minimum prose needed to run each
gate correctly — the invocation, the pass condition, any caveat that changes how you run
it. A gate's rationale, its policy history, and the standing constraints behind it are
repo description: link them, never restate them. This file is read at the moment someone
needs a command, and every paragraph that is not about running a gate moves that command
further away.

Satisfy the gates **whose surface your change actually touches** — every gate names that
surface, and running the rest is waste rather than rigour. Name the ones you skipped and
why, because afterwards a silent skip and a satisfied gate look identical. Task briefs
never restate the gates, and the gates apply regardless of what a brief says.

**A docs-only change is the common case, and it is not ungated.** It needs no build, no
type-check, and no test suite — do not run a long suite to land a typo. It does need
whatever the repo has for prose, usually a link check: moving or deleting a document
breaks links in files the diff never touched.

Do not judge that by eye. Where a repo declares a prose surface — a `DOCS-ONLY` block in
its `definition-of-done.md`, listing paths no gate there reads — ask the predicate
instead: `bash workshop/Tools/docs-only-diff.sh <base-sha>`. Exit 0 takes the docs lane;
exit 1 means run the gates; exit 2 means *cannot decide*, which counts as 1. A repo with
no declared surface has no fast lane, and that is an answer too.

**Run a gate so its exit code survives.** Piping a fallible command through `tail` or
`head` reports the *pipe's* status, so a red run announces itself as success. Redirect
first, then read:

```bash
<gate command> > /tmp/check.log 2>&1; echo "EXIT=$?"; tail -40 /tmp/check.log
```

**A red gate is fixed, not weakened** — not with a new baseline, a broadened
suppression, or a relaxed config. Where a gate genuinely cannot be satisfied, stop and
say so.

## See also

- [`signal-hygiene.md`](signal-hygiene.md) — how to know that any step actually happened
