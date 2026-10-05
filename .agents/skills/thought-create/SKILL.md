---
name: thought-create
description: Capture one thought or a pasted batch of notes into this repository's thoughts folder (docs/work/thoughts/), creating and seeding the folder where it does not exist yet. Takes the thought text as its optional argument.
---

# Capture thoughts

Write brief, unjudged thoughts into this repository's thoughts folder —
`docs/work/thoughts/` — one file per thought, per the format contract in that
folder's `README.md`. This is the first stage of the thought pipeline: capture
writes a thought, a workspace that holds several repositories may sort it to
the repository that owns it, and the `thought-finalize` skill decides what it
becomes.

This skill is deliberately dumb. Its only job is getting text out of the
user's hands and into git with near-zero friction per thought: capture
verbatim, guess cheaply, never interrogate. All judgement about what a
thought *means* or where it should *go* is deferred to sorting and
finalizing.

## Resolve the seed first

The thoughts-folder seed is `docs/templates/thoughts/README.md` in the shared
tree this skill ships in. Resolve it from this skill's **physical** directory:
follow every symlink on the path to `SKILL.md`, then take
`../../../docs/templates/thoughts/README.md` from there, per
[`skill-path-resolution.md`](../../../docs/skill-path-resolution.md). Never
resolve it through a consumer's `.claude/` bridge or assume the tree's mount
name.

## Phase 1 — Check the folder

- **`docs/work/thoughts/` exists** → capture into it as it is. Never replace
  or edit a README that is already there.
- **The folder is absent** → create it and copy the seed into it as
  `README.md`, byte-for-byte. Do not compose a README from memory: a recipe
  followed twice produces two READMEs that differ. Where the repository has a
  `docs/README.md` index, add one line pointing at the new folder.
- **The folder exists without a README** → seed only the README.
- **The seed cannot be read** → capture anyway, skip the README, and say in the
  Phase 5 printout that the folder was not seeded and why. A lost thought costs
  more than a missing README.

Never refuse for lack of a folder, and never write a thought anywhere but this
repository.

## Phase 2 — Collect

- If the skill was invoked with argument text, it is a single thought. Skip to
  Phase 4.
- Otherwise ask the user to paste their notes, and treat the paste as a
  batch.

## Phase 3 — Split the batch

Split the paste into individual thoughts: one per line or bullet, folding
obvious continuation lines (indented fragments, a sentence wrapped across
lines) into the thought above. Drop blank lines and structural headers that
aren't thoughts themselves.

Only when the split is genuinely ambiguous — e.g. a paragraph that could be
one thought or three — show the proposed split and ask. A clean bulleted
list needs no confirmation.

## Phase 4 — Write files

For each thought, create `docs/work/thoughts/<slug>.md`:

1. **Slug**: kebab-case from the thought's key words, roughly 3-6 words
   (`cache-search-results`, not the whole sentence). Never `README` or
   `_TEMPLATE`. If the name is taken, make the slug more specific rather than
   numbering it.
2. **`project-guess:`**, only in a workspace. Where the repository's root
   instruction file (`AGENTS.md`, or `CLAUDE.md` where there is no
   `AGENTS.md`) carries a workspace catalog — a table mapping the projects it
   holds to what each is for — match the thought against it and record the
   best-guess project path in a `project-guess:` frontmatter field. No match,
   or a thought that spans projects with no clear primary → `unknown`. Do not
   ask the user per thought — a wrong guess costs nothing. Everywhere else,
   omit the field and the frontmatter block entirely: the file's location
   already says where the thought lives.
3. **Body**: the thought verbatim. Fix nothing beyond obvious typos the
   user would want fixed; do not rephrase, expand, or editorialize —
   capture that embellishes is capture that loses the original. Name
   every fix beyond punctuation in the Phase 5 printout, and flag any word
   that looks like a dictation error you left alone. Never restructure a
   thought — reordering, adding headers — except to match a correction the
   user already made to a sibling thought. No dates, no fields beyond
   `project-guess:`.
4. **Overlap with an existing thought**: still a new file — never append
   to or edit an existing thought at capture time. Merging is judgement,
   and judgement belongs to the later stages; editing a shared file is
   exactly what one-file-per-thought exists to avoid. Name the suspected
   overlap in the Phase 5 printout instead.

## Phase 5 — Commit

Commit only the paths this run created: the thought files and, when Phase 1
seeded the folder, its README and the index line. Never `git commit -a`. A
batch paste commits once: `Capture N thoughts`. When thoughts arrive one at a
time across a conversation, commit each as it lands, with a message naming
the thought — a captured thought never sits uncommitted waiting for a "that's
all". Push only when asked, by the repository's own landing route.

Then print the list of files created, with each thought's `project-guess:`
value where one was written — plus whether the folder was seeded and from
which path, every fix made, any suspected dictation error left unchanged, and
any suspected overlap with an existing thought — so the user can spot a bad
split, guess, or fix while the notes are still in front of them.
