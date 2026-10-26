# Execution discipline

The rules for implementing a task in the current session. The `task-implement`
skill reads this compatibility path directly; no autonomous worker consumes it.

### Staleness check

**Staleness check.** The brief is a cache of code observations; its
frontmatter `finalized-at: <sha>` records their conservative comparison
baseline. Resolve `task-history-baseline.sh` beside the task-finalize
checker's physical directory and run `check` with the task repository,
inspected `HEAD`, and stamp before constructing a range. `STATUS=usable`
permits `git log --oneline <baseline>..HEAD -- <paths from the brief's Scope section>`
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
criteria govern either way. `STATUS=reverify` — unavailable commit,
non-ancestor, or insufficient history — requires direct verification of
every factual claim, cited construct, recommended-solution premise, and
acceptance criterion against current code. Print the helper's reason and
continue autonomously; do not require interactive re-finalization, rewrite
the stamp, change acceptance criteria, retry the unusable SHA, guess another
commit, or use a date window. A helper execution error must be reported;
continue with direct verification only when current files remain inspectable,
otherwise record the blocker in the brief and report it. Classify an unstamped brief's
creation commit before using its range; if that history is unusable, or the
brief is untracked, use the same full verification path.

### Recommended solution

**Recommended solution.** If the brief carries a
`## Recommended solution`, follow it unless the code at HEAD
contradicts it — it was written from a code-verified analysis and
exists so you don't re-derive the design. It is advisory, not
contract: the Acceptance criteria are what you're graded on. When
you deviate from it, say what you changed and why in the body of
the relevant commit message — don't silently diverge.

### Definition of done

Read `docs/work/definition-of-done.md`; where it exists,
satisfy every applicable requirement in it — the project-wide definition of
done. Your task brief does not restate those requirements; they apply
anyway.

### Acceptance-criteria sentinels

**If you edit the brief's `## Acceptance criteria` section (tick off
items, rewrite the acceptance content), preserve its AC-sentinel
zone.** The section body is wrapped in `<!-- AC:BEGIN -->` /
`<!-- AC:END -->` sentinels so machine tools (validators,
`/task-finalize`, future ecosystem scripts) can edit the AC items
in place. Keep your edits **inside** the sentinel zone — don't
move the sentinels and don't add acceptance items outside.

### Ask with a briefing

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
