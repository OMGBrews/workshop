# Execution discipline

The rules a session follows while turning a task brief into code: distrust the
brief until it is checked against HEAD, treat the recommended solution as advice
and the acceptance criteria as contract, satisfy the project's definition of
done, keep the acceptance-criteria sentinels intact, and brief the human before
interrupting them. Read this before changing what an implementing session is
told — two callers consume it, the autonomous task-queue worker and
`/task-implement`.

## How this file is consumed

Each block below sits between `<!-- block: <anchor> -->` and
`<!-- /block: <anchor> -->` markers, and reaches its two callers differently:

- **The task-queue worker.** `initial-prompt.md` carries a matching
  `<!-- include: execution-discipline.md#<anchor> -->` line wherever a block
  belongs. `render_worker_prompt` in `run.sh` replaces that line with the
  block's body, re-indented to the directive's own indentation, before the
  runner dispatches the prompt — so the worker still reads one flat prompt,
  the same text it read when these blocks were inline. A missing file or an
  unknown anchor aborts the launch rather than dispatching a worker with a hole
  where its discipline should be.
- **`/task-implement`.** The skill reads this file directly at the start of an
  in-session run; nothing is expanded or copied.

So this is live runner configuration, not documentation: an edit here changes
what an unattended worker is told on its next dispatch. Two authoring rules
follow from that:

- **A block body is stored with the line breaks the worker prompt needs.**
  The expansion is a text splice, not a re-wrap: whatever precedes the
  directive on its line stays glued to the block's first line, whatever
  follows stays glued to its last, and interior lines take the directive
  line's indentation. Re-wrapping a block here changes the dispatched prompt,
  which is why `definition-of-done` below opens on a one-word line.
- **Keep the markers on their own lines, and keep block bodies free of
  `include` directives** — the expansion does not recurse.

### Verify the rendered prompt

Render both the committed baseline and the working tree; reading either source
file alone does not prove what the worker receives. From the repo root:

```bash
baseline_dir=$(mktemp -d)
git archive HEAD \
  .agents/skills/task-queue/initial-prompt.md \
  .agents/skills/task-queue/execution-discipline.md |
  tar -x -C "$baseline_dir"

render_prompt() {
  bash -c '
    source .agents/skills/task-queue/run.sh
    SKILL_DIR="$1"
    PROMPT_FILE="$SKILL_DIR/initial-prompt.md"
    render_worker_prompt
  ' .agents/skills/task-queue/render-check "$1"
}

render_prompt "$baseline_dir/.agents/skills/task-queue" > /tmp/before.md
render_prompt "$PWD/.agents/skills/task-queue" > /tmp/after.md
diff /tmp/before.md /tmp/after.md    # empty = the worker reads the same prompt
find "$baseline_dir" -depth -delete
```

## Whose voice this is

The wording addresses the **worker**: a session running unattended in a
worktree, whose brief the runner deletes on its behalf. `/task-implement` runs
the same discipline with a human watching, and inverts four things — it ticks
acceptance criteria as they are met, deletes the brief itself, closes with a
report, and blocks in place. Those inversions are recorded in
[`../task-implement/SKILL.md`](../task-implement/SKILL.md), deliberately not
here: this file has to keep saying what the worker is told.

## The blocks

### Staleness check

Where it goes in the worker prompt: step 1, after the brief has been read.

<!-- block: staleness-check -->
**Staleness check.** The brief is a cache of code observations; its
frontmatter `finalized-at: <sha>` records the commit those
observations were verified against. Run
`git log --oneline <sha>..HEAD -- <paths from the brief's Scope section>`
(whole repo if the brief has no Scope). Before trusting an empty
result, confirm this repo tracks those paths:
`git ls-files --error-unmatch -- <path>`. `git log` prints nothing
and exits 0 for a path that is untracked, gitignored, or in another
repository — byte-identical to its output for a tracked path that
nothing touched. An untracked Scope path means rot is **unknown**,
not absent: verify that path's claims inline instead. Empty output
over paths confirmed tracked → trust the brief as written.
Non-empty → the ground moved after verification:
re-verify the brief's factual claims (Context, Recommended solution,
cited anchors) against the current code before implementing, and
where brief and code disagree, the code wins. The Acceptance
criteria govern either way. A brief with no `finalized-at` stamp
predates verification — treat all of its claims as unverified and
check them as you go.
<!-- /block: staleness-check -->

### Recommended solution

Where it goes in the worker prompt: step 1, immediately after the staleness
check.

<!-- block: recommended-solution -->
**Recommended solution.** If the brief carries a
`## Recommended solution`, follow it unless the code at HEAD
contradicts it — it was written from a code-verified analysis and
exists so you don't re-derive the design. It is advisory, not
contract: the Acceptance criteria are what you're graded on. When
you deviate from it, say what you changed and why in the body of
the relevant commit message — don't silently diverge.
<!-- /block: recommended-solution -->

### Definition of done

Where it goes in the worker prompt: step 2, spliced into the middle of a
sentence-continuous paragraph, between the project's normal conventions and
the commit instruction. That is why its stored wrapping looks arbitrary — the
first line is a single word because the prompt breaks there.

<!-- block: definition-of-done -->
Before
your final commit, look for a `definition-of-done.md` in the tasks
directory (the parent of your brief's `queued/`); where it exists,
satisfy every applicable requirement in it — the project-wide definition of
done. Your task brief does not restate those requirements; they apply
anyway.
<!-- /block: definition-of-done -->

### Acceptance-criteria sentinels

Where it goes in the worker prompt: the `## Interaction` section.

<!-- block: ac-sentinels -->
**If you edit the brief's `## Acceptance criteria` section (tick off
items, rewrite the acceptance content), preserve its AC-sentinel
zone.** The section body is wrapped in `<!-- AC:BEGIN -->` /
`<!-- AC:END -->` sentinels so machine tools (validators,
`/task-finalize`, future ecosystem scripts) can edit the AC items
in place. Keep your edits **inside** the sentinel zone — don't
move the sentinels and don't add acceptance items outside.
(For normal completion you usually don't edit the AC section — the
runner removes the whole file, sentinels and all. Edit it only if
the AC needs updating mid-task to reflect a scope change.)
<!-- /block: ac-sentinels -->

### Ask with a briefing

Where it goes in the worker prompt: the `## Interaction` section, after the
sentinel rule.

<!-- block: ask-with-briefing -->
**Briefing rule (mandatory before any `AskUserQuestion` call).** That tool
fires a push notification to the user's phone, where the popup shows only
the question text and option labels — no view of the codebase, no view of
your preceding reasoning, no view of the planning doc. Without a briefing,
the user has nothing to anchor their decision. Before each call, post a
short context block to the conversation that includes:

1. A one-line summary of the task you're working on (paste from the task
   brief if useful).
2. For each question being asked, 2–4 sentences of plain-English context —
   what the relevant systems / files / concepts are (with paths if
   helpful), what's currently true, and what the decision impacts.

Then call `AskUserQuestion`. Batch up to 4 closely-related questions in
one call (one push notification, one round-trip on the phone); don't ask
three questions and stop without acting on them.

Plain-text questions (ending your turn with a `?`) do NOT fire pushes,
so reserve those for fast in-terminal exchanges when the user is at the
keyboard.
<!-- /block: ask-with-briefing -->
