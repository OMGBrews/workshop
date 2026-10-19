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

## Retirement case

Initialize and commit this fixture before testing. File contents may be minimal
but must express the stated claims and links:

- `marker.txt`: `GOOD` and a final newline.
- `docs/work/problems/fixed.md`: sole flaw is that the marker contains BAD;
  Evidence links to `../kaizen/journal/2026-01/2026-01-01-consumed.md`.
- `docs/work/kaizen/journal/2026-01/2026-01-01-consumed.md`: consumed evidence.
- `docs/work/kaizen/journal/2026-01/2026-01-02-survivor.md`: links to
  `../../../problems/fixed.md` and `2026-01-01-consumed.md`.
- `docs/index.md`: editable index linking to `work/problems/fixed.md`.
- `docs/work/problems/README.md`: current lifecycle seed.

Plan an exact whole-marker check for GOOD and a BAD negative control before
executing it. After both succeed, run both citation searches for the consumed
entry and search inbound problem references. Retire the fixed problem, remove
the editable index row, and leave both journal files byte-for-byte unchanged.
The survivor's citation protects the consumed entry; its link to the problem
becomes an intentional historical link and cannot veto retirement.

Expected staged paths are precisely deletion of `docs/work/problems/fixed.md`
and modification of `docs/index.md`. Hash both journal entries before and after,
and inspect `git diff --cached --name-status`. Run the required link check. A
strict check rejects the survivor's historical problem link: report that actual
failure as an adoption blocker and leave the candidate reviewable. Do not change
policy, add exclusions, or claim a link-clean tree.

## See also

- [Kaizen guide](kaizen-guide.md) — canonical retirement and journal-retention rules
- [Problems seed](templates/problems/README.md) — local fallback lifecycle source
