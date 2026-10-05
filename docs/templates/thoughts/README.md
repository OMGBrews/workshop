# Thoughts

Thoughts and ideas about this project — a sentence or two each — kept here
until they mature into a task, a document, a record, or nothing at all. This
README was seeded from the shared Workshop tree's
`docs/templates/thoughts/README.md`; the copy is this repository's own.

## How a thought moves

1. **Capture.** The `thought-create` skill writes a thought here, one file per
   thought, and seeds this folder the first time it is used.
2. **Sort, where there is a workspace.** A workspace that holds several
   repositories may run a sort that moves a thought captured in the wrong
   place to the repository that owns it — still as a thought, unconverted.
3. **Finalize.** The `thought-finalize` skill, run in this repository, decides
   what each thought becomes, hands it to whatever owns that kind of artifact,
   and deletes the thought in the same commit.

## File format

One file per thought: a kebab-case filename, and the thought itself as the
body.

- **Filename**: kebab-case slug of the thought, e.g.
  `cache-search-results.md`. No numbering, no dates. `README.md` and
  `_TEMPLATE.md` are reserved.
- **Frontmatter**: usually none. A thought captured in a multi-repository
  workspace may carry a single `project-guess:` field naming the project it
  probably belongs to; the guess is dropped once the thought reaches it.
- **Body**: the thought, as close to verbatim as captured. A sentence of
  context may follow; expansion beyond that belongs to finalizing, not to
  capture or sorting.
- **No dates**: creation date comes from
  `git log --diff-filter=A --follow --format=%cs -- <file>` when needed.
- **No status field, no index**: a thought's presence in this folder *is* its
  status — not yet finalized. This README never lists the thoughts; a
  hand-maintained index over many tiny files is the shape that drifts.
- **The one exception is `Waiting for:`.** A thought that `thought-finalize`
  reviewed and judged not ready to mature keeps one appended line,
  `Waiting for: <what>`, naming what would let it mature. A thought with no
  such line has never been reviewed; run from this folder,
  `grep -L '^Waiting for:' *.md` lists those, plus this README.
