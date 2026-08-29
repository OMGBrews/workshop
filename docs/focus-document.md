# Focus documents

A focus document records a repository owner's current direction for the task-selection
skills that read it. This contract governs `<tasks>/focus.md` for both its writers and
readers; repository instructions and skills should link here instead of restating it.

## Format

```markdown
# Focus

<One to five sentences of owner-written prose: what this repository is concentrating
on now and why.>

**Not now:** <optional, one unwrapped line describing deliberately deprioritized work>
```

The complete file is at most 15 lines. The prose states durable direction at a level
above one task, using specific conditions or areas that a reader can quote when deciding
whether a task's goal or scope is in focus. A workspace index may also name the project
in focus.

## Direction, not a next task

A focus document contains no next-action pointer, including prose such as “start with
X”; task selection belongs to the queue and its selection skills. It contains no dates,
rationale essay, changelog, or Markdown link to a task brief. Individual task slugs or
categories may appear only as plain text on the optional `**Not now:**` line, never in
the body prose.

When material no longer fits, route quality bars and rationale to a planning document
and task-shaped work to task briefs; the focus may link to the planning document and
retain a one-sentence conditional summary.

## Writer and reader rules

- `**Not now:**` is optional, begins a line exactly as written, appears at most once,
  and remains one unwrapped source line. A writer replaces that line rather than adding
  a second one; a reader accepts prose without it.
- Ask the owner for the direction. Never infer it from queue contents. Preserve their
  stated direction while trimming or replacing a nonconforming document.
- Rewrite in place. Do not append history; Git already preserves it.
- Readers treat the prose and optional labelled line as separate inputs. A specific,
  quotable prose sentence can lift matching work; the labelled line can actively lower
  work it names.

## See also

- [`focus-update`](../.agents/skills/focus-update/SKILL.md) — the shared writer for this contract
- [`task-reprioritize` ranking rubric](../.agents/skills/task-reprioritize/ranking-rubric.md#focus-weighting-tasksfocusmd) — reader-side matching, weighting, and staleness
- [`check-docs-work-conformance.sh`](../Tools/check-docs-work-conformance.sh) — enforcement of the mechanical subset
