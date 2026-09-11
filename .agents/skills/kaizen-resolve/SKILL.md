---
name: kaizen-resolve
description: Close out a problem document once its flaw is actually fixed — verify the flaw gone from the world's side (evidence, not "the fix task merged"), then delete the document and the journal entries it consumed in one staged change, citation-gated, and prove the remaining links resolve. The problem-side counterpart of the kaizen-review skill's pattern cascade in the journal lifecycle. Invoke when a fix for a documented problem has landed and the record should be retired, when docs/work/problems/ carries documents whose flaws may already be fixed, or when closing a task that references a problem document. A run that cannot produce the evidence stops at the evidence gate and reports a dry run rather than deleting anything; nothing is committed or pushed.
---

# Kaizen Resolve

A document under `docs/work/problems/` persists while its flaw exists and is deleted once the flaw is *verified* gone — and a fix task completing is deliberately not the trigger. This skill is that final step as a ritual: produce the evidence, retire the document, and cascade into the journal entries it consumed. It is the problem-side counterpart of the `kaizen-review` skill, which owns the same lifecycle's pattern cascade; the shared rules live in the guide, not here.

Two properties shape everything below:

- **"Verified gone" is a claim about the world, not about the work.** A merged fix, a deleted task, a commit message saying "fixes X" — none of these are the flaw being gone; they are someone having tried. The evidence gate in Phase 3 demands the world's side: the failing behavior no longer reproduces, the missing gate now exists and catches a mutation, the state the document describes can no longer be found.
- **The deletion cascades, and only this session can perform it.** The document's evidence list — the journal entries it consumed — exists nowhere else; once the file is gone, nothing records which entries it absorbed. So the document and its passing entries go in **one staged change**, each entry behind the guide's citation gate, and never in separate commits.

Repo-agnostic: it works in any project with a `docs/work/problems/` directory and stops cleanly in one without. It **stages** deletions and edits; it never commits and never pushes — every removal sits in `git status` for the human to read and revert before it is real.

**Arguments**: an optional problem-document slug or path. With none, Phase 1 lists the candidates and asks which to resolve.

---

## Phase 1 — Preconditions

1. **Does this repo track problems?** `docs/work/problems/` if it exists — with at least one document besides `README.md`. If the directory is absent, print `This project has no docs/work/problems/ directory — nothing to resolve. Problem documents are filed by the kaizen-review skill when a flaw-shaped cluster appears.` and **stop**. If it holds only the README, say so and stop.
2. **Resolve the lifecycle source.** The guide ships beside this skill wherever the devtools tree lives — in the upstream tree at `docs/kaizen-guide.md`, and under any mount at `<mount>/docs/kaizen-guide.md` — so resolve it in this order:

   1. **Beside this file first**: `<this skill's physical directory>/../../../docs/kaizen-guide.md`, resolved by the physical-directory rule — follow the symlink (`readlink -f`, or equivalent) before taking `..`, so the path lands in the tree the skill actually lives in rather than the consumer's own `docs/`. One rule covers every layout and mount name ([`skill-path-resolution.md`](../../../docs/skill-path-resolution.md)).
   2. **Then the repo-root paths**, kept for repos that mount the docs elsewhere: `<mount>/docs/kaizen-guide.md` from the repo root — where `<mount>` is the name *this* repo mounts the tree under — and the project's `docs/work/kaizen/README.md` where it links the guide.
   3. **Then the no-mount fallback, unchanged**: in a repo that consumes vendored skill copies with no devtools mount at all, the repo's own `docs/work/problems/README.md` must carry the cascade rules — the two greps and the keep-on-live-citation veto, seeded from the tree's `docs/templates/problems/README.md` (resolve the tree root from this skill's physical directory).

   If none of these sources carries the rules, stop and say so — running the cascade from memory is how the lifecycle drifts across repos. Say which source you read: the Phase 6 report names it, so a run that degraded to a thinner source is distinguishable from one that found the full guide.
3. **Read the lifecycle source now** — the guide's "The journal's lifecycle" section where it resolves, and this repo's `docs/work/problems/README.md` always (a seeded copy that may deliberately diverge). Not from memory, and not from this file — the two greps, the veto rules, and the same-commit reasoning are deliberately not restated here. One source per repo, so the skill and the rules cannot disagree.

---

## Phase 2 — Pick the document, and read it whole

If the argument names a document (slug or path), resolve it under `docs/work/problems/` and use it. Otherwise list the candidates — every `docs/work/problems/*.md` except the README — and check recent history for signs a fix landed (`git log --oneline -15`, commits naming a problem's subject). Present the list with whatever signal you found and let the human pick (a choose-one prompt, briefed first: the popup shows no file contents, so the message before it must say what each candidate is and why it might be ready).

Then read the chosen document **in full**, and extract three things before anything else happens:

1. **The flaw's observable shape** — what the document says is wrong, in terms of files, behaviors, and evidence. Phase 3's checks are derived from this, so quote the load-bearing claims rather than summarizing them.
2. **The consumed entries** — every journal entry under `docs/work/kaizen/journal/` the document cites as evidence, by path. This list is what Phase 4 cascades over, and this is the last moment it exists outside git history.
3. **Spawned work** — tasks or other documents the problem references, and anything that references it (Phase 5 needs both directions).

---

## Phase 3 — The evidence gate

Derive, from the document's own description, what the world looks like while the flaw exists — then design a check that distinguishes *fixed* from *unfixed*, and state it before running it.

- **Not evidence:** the fix task merged or was deleted; a commit whose message claims the fix; a doc or changelog saying it is fixed; the code "looking right" on a skim. All of these are true in the world where the fix silently failed.
- **Evidence:** the reproduction the document describes no longer reproduces; the gate the document says is missing now exists *and names a deliberate mutation when you feed it one*; the state the document says is wrong (a config value, a dangling reference, a duplicated body) can no longer be found by the same search that used to find it.
- **Apply `signal-hygiene.md`'s question**: what would this check print if the fix never happened? If the answer matches success, the check is decorative — design another. This is the step most tempting to shortcut when a fix "obviously" landed, and it is the entire reason this skill exists as a gate rather than a deletion convenience.

Three outcomes:

- **Verified gone** — every observable the document claims is refuted by a check you ran in this session, with output you can quote. Proceed to Phase 4.
- **Cannot verify here** — the evidence needs something this session lacks (a deploy, a rebuild, host access, production data). **Stop.** Report a dry run: the checks that would settle it, why each is unavailable here, and where it could run. The document stays; nothing is staged. A dry run is a correct outcome, not a failure of the skill.
- **Partially gone** — some of the flaw remains. Stop and say exactly which observables still reproduce. The document persists while any of its flaw exists; if the fixed part deserves recording, editing the document to narrow it is the human's call, not this skill's.

---

## Phase 4 — The cascade, citation-gated

Only reached with the evidence gate passed. For **each entry** on the consumed list from Phase 2, run the lifecycle source's two greps — the filename form and the prose form — naming the search directories explicitly (in a workspace of gitignored sibling clones, a recursive grep from the root silently searches one repo):

- **Any hit from something still live** — a pattern, another problem document, a task, a CLAUDE.md, a planning doc, **or another journal entry** — and the entry stays. The document consumed it, but something else still depends on it; say in the report which entry survived and what held it.
- **A prose citation from a live, editable artifact** — repair it to a relative link in the same change and keep the entry. A citation the filename grep cannot see is a dependency the next deletion pass will break; repairing it is what keeps the gate honest. (A journal entry is never edited — a prose mention inside one is a keep, full stop.)
- **No live hit** → the entry goes.

Then stage everything together — `git rm <problems-root>/<slug>.md <journal-root>/YYYY-MM/<entry>.md …`, where `<problems-root>` is `docs/work/problems/`, and `<journal-root>` is `docs/work/kaizen/journal/` — **one staged change**, document and passing entries side by side. The same-commit rule and both directions of its reasoning (earlier breaks the live evidence links; later never happens) are the guide's; this is where they are executed.

---

## Phase 5 — Prove the remaining link-space resolves

Deleting a document breaks links in files the diff never touched. Before reporting:

1. **Inbound links to the document**: `grep -rn "<problem-doc-slug>" --exclude-dir=.git docs/ *.md` (extend to other directories the repo links docs from). Sort the hits:
   - **Broken by the deletion** — a task citing the problem for context, a README index row, a "see also". Fix each in the same staged change: indexes lose the row; a task that exists *only* to fix this flaw is likely moot — flag it for the human rather than deleting it yourself.
   - **Already wrong before you arrived** — fix either way, and say so.
2. **Re-run the filename grep for every entry you staged for deletion.** Zero hits outside the staged deletions themselves is the proof; a surviving hit means the citation gate missed a citer — unstage that entry and report it.
3. **Journal entries that link the deleted document dangle, and that is correct.** An entry is a record of what was true when it was written and is never edited. Name them in the report and leave them.

---

## Phase 6 — Report

Print a concise block:

- **The document**, and the flaw it recorded.
- **The lifecycle source** — the file Phase 1 step 2 resolved, by path, and which branch found it (beside this file, a repo-root path, or the `docs/work/problems/README.md` fallback). Always present, so a run that degraded to the fallback announces it rather than looking identical to a full resolution.
- **The evidence** — each check run, what it printed, and why that refutes the flaw's observables. For a dry run: the gate that stopped the pass, the checks that would settle it, and where they could run.
- **The cascade** — every entry staged for deletion alongside the document, and every entry the citation check kept, naming what held it. Both halves: a cascade that reports only its deletions cannot be checked.
- **Links** — inbound links fixed, prose citations repaired, journal entries left dangling by design, and any task flagged as possibly moot.
- **Uncommitted** — the staged deletions and edits, so the human can review `git status` and commit. Suggest a commit message shaped like `docs(problems): retire <slug> — flaw verified gone`.

Do not commit and do not push. The changes are on disk and named; committing them is the human's.

---

## Hard "do NOT" list

- **Do NOT treat a fix task's completion, a merge, or a commit message as evidence.** The gate is the world's side, checked in this session.
- **Do NOT delete a document whose evidence gate did not pass here.** "It was verified last week" is a claim, not a check; re-run the check — it is cheap by construction.
- **Do NOT delete the document and its entries in separate commits**, in either order. One staged change; the guide says why both directions lose.
- **Do NOT delete an entry whose citation check found a live citer** — including another journal entry, whose link you could never repair.
- **Do NOT edit, renumber, or cross-reference a journal entry.** Repairs to prose citations happen in the citing artifact, never in an entry.
- **Do NOT move anything to an archive.** Git is the archive: `git log --diff-filter=D` and `git log -S` find every retired document.
- **Do NOT weaken a check until it passes.** If the honest check says the flaw remains, the outcome is Phase 3's "partially gone" or "cannot verify", and the document stays.
- **Do NOT commit or push.**

## See also

The first three are named rather than linked: each sits at a path that differs per consuming repo — a vendored copy, a submodule mount, or this tree — so no single relative link resolves everywhere (same convention as `task-status/SKILL.md`).

- `docs/kaizen-guide.md` — *The journal's lifecycle*: the citation gate, the two greps, the veto rules, and the same-commit reasoning this skill executes.
- `kaizen-review` — the pattern side of the same lifecycle, and the skill that files problem documents in the first place. Not vendored into every repo.
- `.agents/skills/problem-create/_TEMPLATE.md` — the canonical shape of newly filed problem documents.
- `docs/templates/problems/README.md` — the problems-directory lifecycle this skill closes out, as seeded into each repo.
- `signal-hygiene.md` — the standing rule the evidence gate is an instance of: a check whose pass state a no-op also satisfies reports success and ends the investigation. This repo's copy is linked from `AGENTS.md` and `@`-imported by the root `CLAUDE.md`; the path differs per repo.
