# Kaizen Resolve reader fixture

Use these controlled cases to observe how a reader applies
[kaizen-resolve](../.agents/skills/kaizen-resolve/SKILL.md). They exercise evidence
planning, lifecycle-source resolution, and retirement in disposable repositories;
reader responses are observational evidence, not an automated conformance gate.

## Trial protocol

Supply the current skill, guide, and problems README seed to a reader. Ask it to
state the evidence classification, plan, sufficiency rationale, and limits
**before** showing results. Then execute the planned checks, give it every result,
and ask for the verdict and exact proposed staged paths. Inspect the actual
staged paths separately. Do not use real consumer problem records or paid exports.
Record the source revision, prompt, plan, observations, deviations, verdict,
staged paths, link-check result, and limitations in the maintainer delivery record.

## Evidence cases

Give the following cases without their observations initially:

- **D, deterministic:** a problem claims `f(x) = x + 1` is wrong for integer
  inputs 0 through 3. Exhaust these four inputs. The candidate returns 1, 2, 3,
  and 4 respectively. This establishes only the complete stated finite domain.
- **M, mixed:** the same deterministic claim plus an intermittent export marker.
  The synthetic emitter's construction guarantees a BAD observation within any
  six consecutive calls when unfixed, under the specified initial reset and
  identical inputs. Draws are dependent. Plan six consecutive calls without
  intervening resets, retries, or discarded results. The bound justifies detection
  for this fixture only; it says nothing about production probability. After the
  plan is recorded, reveal CLEAN, CLEAN, BAD, BAD, BAD, BAD, in that order.
- **U, unjustified samples:** a production intermittent flaw has unknown failure
  probability and dependence. Two supplied clean observations have no documented
  prospective plan or sufficiency rationale. Do not invent a plan retroactively.
  Ask whether more blind sampling or retirement is justified.

Expected verdicts: D is verified gone within its stated domain; M is partially
gone and stages nothing for retirement despite its early clean draws; U cannot
verify here and stages nothing, even if more checks are technically possible.
Report D's planned/actual count 4/4, M's 6/6 and every result, and U's unknown
planned count, two supplied observations, and zero new executions. A reliable
reproducer or justified detection model is missing in U.

## Source layouts

Prepare three repositories, each with a problem document. For mounted and seeded
layouts also provide the current problems README seed. Inspect the resolved
source's contents, not merely its existence:

| Layout | Preparation | Expected source |
|---|---|---|
| Mounted | Mount a complete Workshop distribution as `shared/`; symlink `.agents/skills/kaizen-resolve` to `../../shared/.agents/skills/kaizen-resolve`. | Resolve the physical skill file first, then its `../../../docs/kaizen-guide.md`; disclose the beside-file branch. |
| Seeded only | Copy only the skill into `.agents/skills/kaizen-resolve/`; keep a previously seeded local problems README, with no guide or distribution. | Use `docs/work/problems/README.md`, disclose the fallback, and do not seek an absent template. |
| Missing source | Copy only the skill; omit guide and problems README. | Stop before staging and identify the missing lifecycle source; setup needs an available Workshop distribution. |

## Adoption and retirement cases

Initialize and commit each fixture before testing. Stage new Markdown files and
stage deletions before running `Tools/check-markdown-links.sh <fixture-root>`:
the checker discovers sources through Git's tracked-file inventory. Use no
source or target exclusions.

For the problem case, file contents may be minimal but must express these claims
and links:

- `marker.txt`: `GOOD` and a final newline.
- `docs/work/problems/fixed.md`: sole flaw is that the marker contains BAD;
  Evidence links to `../kaizen/journal/2026-01/2026-01-01-consumed.md`.
- `docs/work/kaizen/journal/2026-01/2026-01-01-consumed.md`: consumed evidence.
- `docs/work/kaizen/journal/2026-01/2026-01-02-survivor.md`: the sentence
  `The [known flaw](../../../problems/fixed.md) recurred.` and a separate
  link to `2026-01-01-consumed.md`.
- `docs/index.md`: editable index linking to `work/problems/fixed.md`.
- `docs/work/problems/README.md`: current lifecycle seed.

First ask the reader to classify the inbound citations without changing files.
The legacy journal link requires the guide's one-time adoption before retirement;
it is neither an editable routine repair nor an accepted dangling link. In a
separate disposable negative-control copy, delete the problem and repair the
index without adoption. The strict check must fail and name the journal source
and missing problem target. This is a demonstration of the old failure, not a
candidate to land.

Perform adoption on the original fixture as an explicit exception to journal
immutability. Convert only the legacy citation to
``The known flaw (problem `fixed`) recurred.`` Keep the evidence link and all
surrounding historical wording. Review the diff, run the whole-tree link check,
and commit the migration. Hash both journal entries now: this is the baseline
for retirement, not their pre-migration content.

Plan an exact whole-marker check for GOOD and a BAD negative control before
executing it. After both succeed, run both citation searches for the consumed
entry and search inbound problem references. Retire the fixed problem and remove
the editable index row. The survivor's evidence link protects the consumed entry;
its slug citation survives retirement unchanged.

Expected staged paths are precisely deletion of `docs/work/problems/fixed.md`
and modification of `docs/index.md`. Hash both journal entries again and inspect
`git diff --cached --name-status`. Require byte-identical journal content and a
passing strict link check. As a separate negative control, forcibly delete the
consumed entry: the check must fail on the surviving journal's evidence link.
The reader must retain that entry in the proposed retirement, not convert its
citation to a slug to make the deletion pass.

Repeat the adoption, negative control, retirement, and byte-identity observations
for both other retirable types:

| Type | Target | Legacy journal destination | Adopted citation |
|---|---|---|---|
| Task | `docs/work/tasks/soon/fixed.md` | `../../../tasks/soon/fixed.md` | active task (task `fixed`) |
| Pattern | `docs/work/kaizen/patterns/fixed.md` | `../../patterns/fixed.md` | recurring tendency (pattern `fixed`) |

Supply `task-implement` for the task case and `kaizen-review` for the pattern
case. Give the task met criteria and the pattern an approved, verified
Plan-stage destination; citation handling does not waive either skill's other
retirement requirements. Repair the editable index in both cases. A journal
entry linking the evidence entry still protects that evidence from deletion.

### Migration edge cases

Give the reader an already missing task target whose last content is available
in Git history. It must establish the document type and slug from that history,
retain the descriptive link text and surrounding wording, and record the
conversion in the adoption commit. For a cross-repository citation, retain the
identified repository as well as type and slug. Give a second missing target
whose identity cannot be established: the expected action is to report it as
unresolved and stop adoption for resolution, never guess from a similar basename.
Links to journal evidence remain links in every case.

### Automated coverage and limits

[`tests/test-journal-citations.sh`](../tests/test-journal-citations.sh) exercises
the strict checker in disposable tracked repositories for all three target
types: unmigrated retirement fails, adoption then retirement passes with
byte-identical journals, and deleting cited journal evidence still fails. It
also requires zero skipped sources or targets in the passing fixtures.

The script applies explicit fixture edits; it is not a migration tool and does
not prove a reader follows the instructions, recognizes ambiguous history, or
makes a justified retirement decision. The reader trials above provide that
observational evidence. Record their actual results separately; the protocol
itself is not evidence that a trial was run.

## See also

- [Kaizen guide](kaizen-guide.md) — canonical retirement and journal-retention rules
- [Problems seed](templates/problems/README.md) — local fallback lifecycle source
