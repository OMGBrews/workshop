---
name: problem-status
description: Read-only status report on this repository's problem documents — sweep every record briefly with no argument, or inspect one record in depth when given its path. Uses current low-cost evidence to distinguish flaws that remain, may be fixed, have drifted premises, cite rotted evidence, or cannot yet be settled.
---

# Problem status

Answer one question: **what is the current status of this problem — or, with no
argument, of every problem recorded in this repository?** Read the records and
check current, inexpensive signals. Do not turn this into the history-per-claim
investigation owned by `problem-audit`.

**Strictly read-only.** Never edit a problem, stamp it, stage changes, scaffold a
directory, or run a corrective command. Scope is the current repository only:
do not inventory sibling clones. Route a supported indication that a flaw may be
gone to `kaizen-resolve` for its separate evidence-gated retirement check, and
route a record needing historical re-verification to `problem-audit`.

**Arguments**: an optional path to one problem document.

## Locate the records

The problems root is `docs/work/problems/`.

- With no argument, inspect every immediate `*.md` file except `README.md`. If
  the directory is absent, say this repository has no problems collection. If
  it contains no records, report the empty collection explicitly.
- With a path, resolve exactly one file beneath this repository's
  `docs/work/problems/`, excluding `README.md`. Refuse an ambiguous match or a
  path outside that root. If the file does not exist, say so and stop.

Read each selected record in full. Use its H1 as the title. Use the first
sentence of `**In brief**` as the summary when present. Legacy prose layouts are
valid: when `In brief` is absent, summarize the scope statement or flaw text and
label that summary as a fallback. Missing headings from the current template,
including `In brief` or Evidence, do not by themselves make evidence rotten.

## Check current signals

For each record, use only low-cost present-state evidence:

1. Identify the flaw, its scope, cited paths or constructs, supporting evidence,
   and inbound or outbound references.
2. Check whether paths cited inside this repository still exist and whether the
   named constructs are still present. A path outside the repository is a
   limitation, not permission to search sibling clones.
3. Search explicit repository paths for references to the problem filename,
   slug, or a suitably distinctive subject phrase. Do not rely on an ignored
   recursive search whose omissions are invisible.
4. Review a small recent commit list for messages naming the problem's subject.
   Commit messages are leads, never proof that the flaw remains or is fixed.

Do not window git history separately for every cited path or construct. That
depth belongs to `problem-audit`.

### The untracked-path guard

Never call a quiet path history a clean result until the repository tracks the
path. `git log <sha>..HEAD -- <path>` prints nothing and exits successfully for
a gitignored path or a path in a sibling clone. Before interpreting any path
history, check it with `git ls-files --error-unmatch -- <path>`. If it is not
tracked by this repository, report the limitation; do not claim there were no
changes.

## Assign the verdict

Use exactly one of these verdicts for every selected record:

- **Still present** — current supporting evidence shows the documented flaw
  still exists.
- **Likely fixed** — current evidence supports that the flaw may be gone, but
  `kaizen-resolve` must independently verify it before retirement.
- **Premise drifted** — assumptions underlying the record changed enough that
  its original framing no longer describes the current state.
- **Evidence rotted** — cited support is missing, inaccessible, or no longer
  usable, so the record's evidence cannot substantiate its claim.
- **Cannot tell** — available low-cost evidence cannot settle whether the flaw
  exists.

Do not infer a whole-record fix from one corrected observable. Explain mixed
findings and choose the verdict that best represents the unresolved flaw. Do
not treat missing current-template headings in a legacy record as evidence
rot. Unknown evidence is **Cannot tell**, not a silent clean result.

## Report

With no argument, print one concise line per record containing its title, the
summary (noting any legacy fallback), and verdict. Then report the total; keep
empty and absent collections distinguishable.

For one record, report:

- the path, title, and summary;
- the current signals checked and what they show;
- relevant citations to or from the record;
- tracking, repository-boundary, or other evidence limitations;
- the verdict and its evidence-based explanation;
- the appropriate follow-up, if any: `kaizen-resolve` for **Likely fixed** or
  `problem-audit` when historical verification is needed.

Never edit the record as part of reporting its status.
