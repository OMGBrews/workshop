---
name: problem-create
description: Create a prose problem record for a flaw that exists today, using the canonical template and preserving each repository's local problems guidance.
---

# Create a problem record

Create one document under this repository's `docs/work/problems/` for a flaw
that exists now. A problem records the state of the world; it does not prescribe
a solution or carry acceptance criteria.

**Arguments**: an optional flaw name or path, plus any details the user already
provided about the flaw. Treat the full request as input before asking for more.

## Resolve the canonical files first

The canonical template is `_TEMPLATE.md` beside this skill. Resolve both it and
the problems-directory seed from this skill's **physical** directory: follow
every symlink on the path to `SKILL.md`, then resolve `_TEMPLATE.md` beside it
and `../../../docs/templates/problems/README.md` from there. Follow
[`skill-path-resolution.md`](../../../docs/skill-path-resolution.md); never
resolve from a consumer's `.claude/` bridge or assume the shared tree's mount
name. Before writing, disclose the template and seed paths actually read.

If the template is missing or unreadable, stop. It is the single source; do not
reconstruct it from this skill or create `docs/work/problems/_TEMPLATE.md`.

## Phase 1 — Check the repository shape

Check the directory and its README independently:

- If `docs/work/problems/` is absent, offer to create it and seed its
  `README.md` from the physically resolved problems README.
- If the directory exists but `docs/work/problems/README.md` does not, offer to
  seed only the missing README.
- If either exists, preserve it. Never replace a customized README or alter an
  existing problem record while scaffolding.

If scaffolding is declined, stop. Copy only the seed README; the canonical
problem template stays inside this skill.

## Phase 2 — Name and understand the flaw

Use details already supplied in the request before asking for anything. Gather
only what is still needed:

1. A flaw-focused name. Convert it to a kebab-case filename with no date prefix.
   Reject `README.md`, `_TEMPLATE.md`, non-kebab-case names, and path traversal.
2. A short title and a required `**In brief**` paragraph. The paragraph says in
   plain language what is wrong, why it matters, and where it stands. Keep out
   jargon, identifiers, and file paths so a reader new to the repository can
   triage it.
3. Any supplied scope, flaw detail, evidence, impact, background, and related
   material. Ask for missing facts only when the record would otherwise
   misrepresent the flaw. Never invent an observation or fill a section by
   inference merely to remove its guidance.

Before writing, check the exact destination. If it exists, refuse the collision
and report the path; do not overwrite, merge, suffix, or edit it.

## Phase 3 — Create the record

Copy the physically resolved `_TEMPLATE.md` to
`docs/work/problems/<flaw-name>.md`, then:

1. Replace `# Flaw title` with the sentence-case title.
2. Fill `**In brief**` and remove its guidance comment.
3. Fill each section for which the user supplied facts and remove that section's
   guidance comment.
4. Keep all six headings in a new record: `Scope statement`, `The flaw`,
   `Evidence`, `Impact`, `Background`, and `See also`. Where facts were not
   supplied, leave the section guidance in place for later editing.
5. Strip the template-only preamble and footer comments.

Do not add YAML frontmatter, a solution section, acceptance criteria, or a
date-prefixed filename. A concrete fix belongs as one line under See also or in
a task.

## Phase 4 — Report

Print `Created docs/work/problems/<flaw-name>.md.`, followed by the template
path read. Do not commit or push.
