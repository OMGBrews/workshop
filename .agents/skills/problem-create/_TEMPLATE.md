<!-- Template for problem documents. Copy this file to
     `docs/work/problems/<bucket>/<flaw-name>.md`, fill it in, and delete this preamble
     plus the footer comment at the end.

     Filename: kebab-case after the flaw, with no date prefix. `README.md` is
     reserved for the directory guide.

     Audience: people investigating a flaw that exists in this project today,
     or scoping work that may remove it.

     Key references:
       - the repository's `docs/work/problems/README.md` — local lifecycle and
         authoring guidance
       - `problem-create` — creates a record from this template
       - `problem-status` and `problem-audit` — assess whether a record still
         matches the world
       - `problem-plan` — decides what to do about a record, and writes its
         Disposition line when the decision is to live with the flaw
       - `kaizen-resolve` — verifies a flaw gone before retiring its record

     Disposition: a new record carries none. `problem-plan` adds one line,
     never a frontmatter field, directly after the In brief paragraph (after
     an `**Issues**:` line where the repository uses one) when the user
     decides to live with the flaw:
       **Disposition**: Accepted YYYY-MM-DD. <why living with it beats fixing it>
       **Disposition**: Deferred YYYY-MM-DD until <condition>. <one sentence>
     A record planned into a task carries no Disposition line; the task citing
     it is the mark. -->

# Flaw title

**In brief**: <!-- REQUIRED. One short plain-language paragraph for triage:
     what is wrong, why it matters, and where it is observed. Avoid jargon,
     identifiers, and file paths. Someone new to the repository should
     understand it without reading the sections below. -->

## Scope statement

<!-- One paragraph naming the flaw, the affected surface, and who should care. -->

## The flaw

<!-- Describe what is wrong in concrete terms. Name relevant behavior, files,
     commands, or systems, but do not prescribe a solution. -->

## Evidence

<!-- Record current, checkable observations: reproductions, outputs, links,
     or exact paths and constructs. Do not invent evidence to fill this section. -->

## Impact

<!-- Explain what breaks, what becomes harder, or what risk the flaw creates. -->

## Background

<!-- Explain how the flaw came to exist when that history helps the reader.
     Delete this section later when there is nothing useful to say. -->

## See also

<!-- Link related problem records, standards, evidence, or tasks. If a fix
     approach is already obvious, mention it in one line here or file a task;
     do not add a solution section or acceptance criteria to this record. -->

<!-- See also (for template readers, not authored problem documents):
       - `docs/templates/problems/README.md` — seed for a repository's local
         problems-directory guide
       - `docs/kaizen-guide.md` — routes flaw-shaped kaizen findings here -->
