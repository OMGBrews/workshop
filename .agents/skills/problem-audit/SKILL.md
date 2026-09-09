---
name: problem-audit
description: Read-only staleness audit of this repository's problem records against current evidence and usable git history — every record at repo breadth, or one record in depth. Use to re-verify whether documented flaws and their evidence still hold; retirement remains with `kaizen-resolve`.
---

# Audit problem records

Determine whether documented flaws still exist. Audit every problem record in
this repository when invoked without an argument, or one named record in depth
when given a path, filename, or title.

This skill is **strictly read-only**. Do not edit, stamp, move, stage, delete, or
commit a record, and do not run corrective commands. Even a likely fix is only
a finding: `kaizen-resolve` owns the separate verification and retirement gate.

## Scope and modes

- The records root is `docs/work/problems/`. If it is absent, report that no
  problems directory exists and stop.
- With no argument, audit each `docs/work/problems/*.md` file except
  `README.md`. Stay inside this repository; never inventory sibling clones.
  Keep the sweep broad, with one verdict per record and details for limitations
  or mixed findings.
- With an argument, resolve exactly one record. Accept an exact path, filename,
  or H1 title. If more than one record matches, list the matches and ask which
  one; if none matches, report that and stop. Read the named record and its
  cited evidence at full depth.
- If the collection is empty, say so explicitly. Do not treat an absent or
  empty collection as proof that no flaws exist.

## Read the record

Extract the H1 title, the `**In brief**:` paragraph, its scope and flaw claims,
each cited path or construct, and any supporting or contrary evidence it names.
Accept legacy prose layouts without migration. When `In brief` is absent,
summarize the scope/flaw prose and disclose that fallback. Missing headings
from the current problem template are not, by themselves, stale evidence.

Treat every assertion as a claim to re-check, not as current truth. Re-read the
named constructs and their surrounding behavior at HEAD. Search for the
specific feature, rule, test, configuration, or documentation the record
describes. Commit messages are leads, never proof.

## Establish a usable history baseline

Work from the repository that owns the problem record. First confirm the record
is tracked:

```bash
git ls-files --error-unmatch -- <problem-file>
```

For a tracked record in a complete checkout, derive its creation commit through
renames rather than using a date:

```bash
git log --diff-filter=A --follow --format=%H -- <problem-file>
```

Use the oldest returned creation commit. Before using `<sha>..HEAD`, confirm
all of the following:

1. the SHA names an available commit (`git cat-file -e <sha>^{commit}`);
2. it is an ancestor of HEAD (`git merge-base --is-ancestor <sha> HEAD`);
3. the repository is not shallow and the creation history is sufficient; and
4. each in-repository path being compared is tracked, using
   `git ls-files --error-unmatch -- <path>`.

Only then inspect `<sha>..HEAD` for the relevant tracked paths and constructs.
Never substitute `--since`, a recent fixed window, an unrelated commit, or a
fabricated baseline. Do not use task-only baseline helpers.

If the record is new or uncommitted, its creation commit is unavailable or no
longer ancestral after rewritten history, the checkout is shallow, or another
guard fails, skip the historical comparison. Directly re-read the claims at
HEAD and state exactly why history comparison was unavailable. Empty output
from `git log` is evidence of no relevant commits only after all guards pass;
for an untracked or external path it proves nothing.

## Evidence owned by another repository

A cited path may resolve into a mounted tree, ignored nested checkout, or other
repository. Determine the owning git root before interpreting its history. If
the path belongs to another repository and is available, inspect only the
specific cited evidence there. Do not apply the problem record's creation SHA
or its `<sha>..HEAD` range to that repository, and do not broaden the audit into
an inventory of that repository. State that cross-repository history was not
compared. If the owning repository or named evidence is unavailable, report
the limitation rather than calling the citation clean or broken.

## Reach a verdict

Use exactly one of these verdicts for each record:

- **Still present** — current evidence supports that the documented flaw still
  exists.
- **Likely fixed** — current evidence supports a fix, but the independent
  world-side verification required by `kaizen-resolve` has not retired it.
- **Premise drifted** — an assumption underlying the record has changed enough
  that the original claim no longer describes the present system.
- **Evidence rotted** — cited support is now unusable or no longer establishes
  what the record claims.
- **Cannot tell** — the available evidence cannot settle whether the flaw
  remains.

Choose from evidence, not from checklist shape or silence. When findings are
mixed, select the verdict best supported overall and explain which observables
remain, changed, or could not be checked; do not imply that every observable
is fixed.

## Report

For each audited record, report:

- path, title, and `In brief` summary (or the disclosed legacy fallback);
- the creation baseline and history range used, or the precise fallback reason;
- current supporting, contrary, and missing evidence, including which cited
  paths were tracked and which belonged elsewhere;
- the verdict and the facts that justify it; and
- the next owner when action is warranted: `kaizen-resolve` for **Likely
  fixed**, or ordinary task planning when the flaw still needs a fix.

In repo-wide mode, lead with the record count and a compact one-line result for
every record, then expand only material evidence and limitations. In single
mode, give claim-by-claim evidence. End by reaffirming that no files were
changed.
