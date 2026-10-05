---
name: thought-finalize
description: Decide what a thought in this repository's docs/work/thoughts/ should become — a task, a problem record, an idea document, a record, an amendment to a standard, a kaizen entry, or nothing — hand it to that destination's owner, and delete the thought in the same commit. A finalized thought is gone, often replaced by something that is not finalized itself, such as a new task. Takes an optional thought filename; with none, works through the whole folder.
---

# Finalize a thought

Take a thought — a sentence or two in this repository's `docs/work/thoughts/`
— and run it to a conclusion: decide what it should become, hand it to
whatever owns that kind of artifact, and delete the thought in the same commit
as the thing that absorbed it. This is the last stage of the thought pipeline:
`thought-create` captures, a workspace that holds several repositories may
sort each thought to the repository that owns it, and this skill decides, in
that repository, with its code in front of you.

A finalized thought is **gone**. What replaces it is often not finished
itself: a task filed here still needs its own finalization before anyone
builds it. This stage turns an unjudged note into an artifact with an owner,
and stops there. It is a short interview, not a review — no subagents, and
any model will do.

The skill decides and delegates, and owns no template of its own. Tasks go
through `task-create`, problem records through `problem-create`, kaizen
entries follow the kaizen guide, records follow the repository's own
instructions, and idea documents start from the shared idea template. It
writes documents and records itself, and **never code**: a change to code
becomes a task, because code needs the repository's tests and definition of
done.

**Arguments**: an optional thought filename (with or without `.md`) or path.
With one, finalize that thought. With none, work through the folder — see
[Working through the folder](#working-through-the-folder).

## Resolve the shared files first

Resolve these from this skill's **physical** directory — follow every symlink
on the path to `SKILL.md`, then take the relative path from there — per
[`skill-path-resolution.md`](../../../docs/skill-path-resolution.md). Never
resolve them through a consumer's `.claude/` bridge or assume the tree's mount
name.

| Path from the skill directory | Used for |
|---|---|
| `../../../docs/templates/ideas/README.md` | Seeding `docs/planning/ideas/` where it is absent |
| `../../../docs/templates/idea-doc.md` | Writing a new idea document |
| `../../../docs/templates/thoughts/README.md` | The thoughts-folder format, including the `Waiting for:` line |
| `../../../docs/cross-repo-handoffs.md` | Work owed to another repository |
| `../../../docs/kaizen-guide.md` | Writing a kaizen journal entry |

Read a file when its destination comes up, not all of them up front, and name
every one you read in the report. If a file the chosen destination needs
cannot be read, stop that hand-off and say so rather than reconstructing it.

## What counts as a thought

Every `*.md` file directly in `docs/work/thoughts/` except `README.md` and
`_TEMPLATE.md`. A thought may carry a `project-guess:` frontmatter field, a
`Waiting for:` line from an earlier run, or a generated filename suffix; all
of them are ordinary thoughts. If the folder is absent or holds no thoughts,
say so and stop.

## The procedure, for one thought

Read the thought, then:

### 1. Check it is home and still true

- **Not home** — the thought is about a different repository than this one.
  This is a judgement, not a lookup: compare what the thought is about with
  the repository in front of you. Leave the file untouched, and say that a
  workspace-level sort is what moves a thought between repositories. This
  skill never moves one.
- **Dead** — already done, overtaken by later work, a duplicate of something
  that exists, or a capture test. Check the repository where that is cheap —
  a grep, a look at the task queue — then propose deletion, with the evidence,
  and ask nothing more.

### 2. Disambiguate, only if the shape is unclear

Ask a question or two — enough to tell a flaw from a fix from an idea, and no
more. Most thoughts cannot be classified from their text alone, so asking is
normal; interrogating is not.

### 3. Propose the destination and confirm it

Walk the table from the top; the first yes decides. Propose that destination
with a one-line reason and get the user's confirmation before going further.
The mapping is many-to-many: one thought can yield a problem record and the
task that fixes it, and several thoughts can be one piece of work. Say so when
you see it.

| Test | Destination | Conversion |
|------|-------------|------------|
| Information to keep, not work to do | Record | Written where the repository keeps records, per its own instructions |
| Something is wrong today, and "verified gone" is a real endpoint | Problem record | `problem-create`, plus a task where the fix is already concrete |
| Concrete work with a statable done-condition | Task | `task-create`, into a planning bucket |
| A question | Its answer | Answered now if cheap, then run back through this table; otherwise an idea document carrying the open question |
| A direction, design, or possible project | Idea or planning document | Written from the idea template into `docs/planning/ideas/`, or added to the document that already covers it |
| A rule about how we work | The standard that owns it | Edited directly, or filed as a task in the repository that owns the standard |
| Fresh friction in how we build | Kaizen journal entry | The repository's journal, per the kaizen guide |
| None of these yet | Stays a thought | One appended `Waiting for:` line |

### 4. Gather only what that destination's creator needs

A goal statement for a task, the facts of the flaw for a problem record,
nothing at all for a thought that is already a complete recipe. Do not run
the destination's own interview in advance: the task and problem skills ask
their own questions, and `task-finalize` owns the deep interview for a task.
One idea should not be interviewed three times.

### 5. Hand off

Per destination, as [Hand-offs](#hand-offs) describes.

### 6. Delete the thought and commit

Delete the thought **last**, and only when something absorbed it or it was
judged dead — in the same commit as the artifact that absorbed it, as
[Committing](#committing) describes. Until that commit exists, the thought is
still on disk, so an abandoned hand-off never loses it. Two exits delete
nothing: *not home*, and *not ready*.

## Hand-offs

### Task

Follow the `task-create` skill through writing the file: the goal statement
from step 4 answers its goal question, and its bucket default stands unless
the user says otherwise. Stop after its confirmation phase. Do **not** take
its finalize offer or its ship step yet — both would strand the thought's
deletion: `task-finalize` commits only the task's own files, and
`task-create`'s ship step expects `git status` to show the task file alone.

Instead, commit the task, any tasks-root scaffolding `task-create` created,
and the thought's deletion together. Only then relay the offer: run
`task-finalize` on the new task now, or leave it for later.

### Problem record

Always through `problem-create`, never by hand. It seeds a missing
`docs/work/problems/README.md`, and a record written into a repository without
that README fails the shared work-directory conformance check. It never
commits, so its record and any README it seeded go into this skill's commit.
Where the fix is already concrete, file the task too (above), in the same
commit.

### Idea or planning document

- **An existing document already covers the direction** → add to it rather
  than writing a sibling.
- **`docs/planning/ideas/` exists** → read its `README.md` first and follow
  it. Its layout — topic subfolders, an index table, a local `_TEMPLATE.md` —
  is that repository's choice. The shared template and seed apply only where
  the local README is silent, and a hand-kept index the README asks for gets
  its new row.
- **The folder is absent** → create it, copy the ideas seed into it as
  `README.md` byte-for-byte, and write the document as
  `docs/planning/ideas/<kebab-case-name>.md`.

Write the document from the idea template, filled from the thought and the
discussion, with every unanswered question left under its open-questions
heading. A long-lived maybe belongs here rather than in the thoughts folder:
an idea document is the genre that is allowed to sit indefinitely.

### The answer to a question

If a grep or a quick read answers it, answer it, then run the answer back
through the table — it usually becomes a task, an amendment, or nothing. If
it cannot be answered cheaply, write an idea document that carries the
question under open questions.

### Amendment to a standard

- **The standard is a document in this repository** → edit it directly, in
  the same commit as the deletion.
- **The standard is code, or a check** → a task, because this skill never
  writes code.
- **The standard lives in another repository** → work owed to that
  repository: a handoff, below.

### Record

Write it where the repository keeps that kind of record, following its root
instruction file and the README of the target folder. Where the instructions
state no convention for this kind of record, ask rather than invent one.

### Kaizen journal entry

Only for fresh friction in how we build — never a feature idea. The entry
needs a kaizen tree, `docs/work/kaizen/` with its `journal/` and `patterns/`.
Where it is absent, offer the `kaizen-init` skill first, or propose another
destination; never create the tree by hand, because its scaffolding is what
the conformance check verifies. Write the entry at the path and in the
format the kaizen guide's "Recording" section gives. Anything `kaizen-init`
created rides in this skill's commit.

### Work owed to another repository

A task that belongs to another repository is a handoff, delivered per the
shared cross-repo handoffs guide. Address the repository that holds the
receiver's task queue, and name it only as the guide's `owner/repo` value.

- **Blind** — the receiving repository is not on this filesystem, which is
  the usual case. Write the task-shaped brief into this repository's
  `docs/work/handoffs/` with `handoff-to: <owner/repo>`, in the same commit as
  the thought's deletion. The guide counts a blind handoff as filed only once
  it is pushed, so say that in the report.
- **Sighted** — the receiving repository is on disk. Write the task into its
  `docs/work/tasks/soon/` with `handoff-from: <owner/repo>` and commit it
  there first; then commit the thought's deletion here. One commit cannot span
  two repositories, and destination-before-source means an interruption
  leaves the thought existing twice rather than nowhere.

### Not ready yet

The thought stays. Append one line to the end of its body, after a blank
line:

```text
Waiting for: <what would let this thought mature>
```

The fixed prefix is what tells a reviewed thought from one never looked at.
If the thought already has a `Waiting for:` line, replace it rather than
adding a second. Commit the edit on its own. A thought that is merely a
long-lived maybe is not "not ready": it becomes an idea document, so the
thoughts folder still drains.

## Committing

- **One commit per finalized thought**, holding the new artifact or
  artifacts, any scaffolding created on the way — a seeded problems or ideas
  README, a new tasks root, a kaizen tree — and the thought's deletion
  (`git rm`). The scaffolding belongs in that commit even when the skill that
  created it leaves committing to its caller; left out, the tree fails the
  work-directory conformance check until someone notices.
- **A batch of dead-thought deletions may share one commit.**
- **Path-scoped.** Read `git status --short` first, then commit by naming
  each path. Never `git commit -a` or a broad `git add`: other work in the
  tree is not this skill's to sweep up.
- **The message says what the thought became**, in the repository's commit
  style — for example "Finalize thought cache-search-results into a task".
- **Never push.** Landing is the user's call, by the repository's own route.

## Working through the folder

With no argument:

1. **Read every thought** and list them, one line each: the thought's name,
   the proposed disposition, and a short reason. Show an existing
   `Waiting for:` line beside its thought and say whether it now looks met.
2. **Mark the ones that need no questions** — those whose proposed
   disposition can be carried out with nothing further from the user: a dead
   thought's deletion, a not-home thought left alone, and a conversion whose
   creator needs no input, such as a thought that is already a complete
   recipe. Anything bound for `task-create` or `problem-create` is never in
   this group; both ask.
3. **Ask for one confirmation** covering exactly that group as listed. The
   user may strike any line into the interview pile instead.
4. **Carry the group out and commit**, per [Committing](#committing).
5. **Interview the rest one at a time**, in listing order unless the user
   picks another, each through the full procedure. The user may stop after
   any thought; everything not yet finalized stays exactly as it was.

## Report

Close with:

- **Each thought and what became of it** — the artifact path, deleted, left
  in place as not home, or waiting for what.
- **Commits made**, with hashes, and a plain statement that nothing was
  pushed — plus, for a blind handoff, that it is not filed until it is.
- **Shared files read**, by path.
- **Offers still open** — finalizing a new task, initializing kaizen, or
  anything the user deferred.
