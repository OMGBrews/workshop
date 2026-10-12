---
name: kaizen-init
description: Scaffold the kaizen continuous-improvement system into this project — create docs/work/kaizen/ from the shared templates and add a pointer to the project's root instruction file (`AGENTS.md`)
---

# Kaizen Init

Set up the kaizen continuous-improvement system in the current project. Kaizen is a continuous-improvement practice for improving **how we build** — see the canonical guide at `<devtools root>/docs/kaizen-guide.md` (`<devtools root>` is the tree root resolved from this skill's physical directory — Phase 1 step 1). This skill is idempotent: if the kaizen root already exists — `docs/work/kaizen/` — it reports what's present and only fills gaps, never overwriting existing journal or patterns content.

**Arguments**: none. The skill operates on the current project.

Run the phases in order.

---

## Phase 1 — Preconditions

1. Confirm the project mounts the devtools tree (the skills symlink already implies this). Resolve the tree root from this skill's physical directory — `<devtools root> = $(dirname "$(readlink -f <this skill file as the repo reaches it>)")/../../..` (the physical-directory rule, [`skill-path-resolution.md`](../../../docs/skill-path-resolution.md)) — and use it throughout. The shared guide lives at `<devtools root>/docs/kaizen-guide.md` and the templates at `<devtools root>/docs/templates/kaizen/`.
2. Confirm there is a `docs/` directory. If the project keeps docs elsewhere, target that location instead and note the difference in the final report.
3. Check whether the kaizen root already exists — `docs/work/kaizen/`. If it does, list its contents and treat this as a top-up run (Phase 2 only creates missing files). A `journal.md` or `patterns.md` **file** there means the project predates the directory layout — Phase 2 converts it rather than scaffolding alongside it.

---

## Phase 2 — Scaffold `docs/work/kaizen/`

Create the directory tree and copy the starter files from the templates, **only for files that do not already exist** (portable, idempotent — never overwrites existing kaizen content). The target root is detection-first: a top-up run writes into the existing root `docs/work/kaizen/`, and a fresh scaffold creates `docs/work/kaizen/`:

```bash
KAIZEN_ROOT="docs/work/kaizen"
mkdir -p "$KAIZEN_ROOT/journal" "$KAIZEN_ROOT/patterns"
for f in README.md journal/README.md patterns/README.md; do
  if [ -e "$KAIZEN_ROOT/$f" ]; then
    echo "exists, skipping: $KAIZEN_ROOT/$f"
  else
    cp "<devtools root>/docs/templates/kaizen/$f" "$KAIZEN_ROOT/$f"
  fi
done
```

(The existence guard replaces `cp -n`, whose no-clobber behavior is non-portable and emits a warning on GNU coreutils.)

Journal entries are one file per entry under `<kaizen root>/journal/YYYY-MM/`; the month directories are created by whoever writes the first entry of a month, not here. The two directory `README.md` files carry the filename convention and are what make an empty `patterns/` trackable by git.

**If the project already has a single-file `<kaizen root>/journal.md`** (the pre-2026-07 layout), do not scaffold over it — convert it instead, then re-run this phase for anything still missing:

```bash
bash "<devtools root>/Tools/migrate-kaizen-journal.sh"
```

Then substitute the mount name into the copied `<kaizen root>/README.md`: the template's guide link carries the placeholder `<devtools-root>`, and this step replaces it with the name this project actually mounts the tree by — `MOUNT_NAME="$(basename "<devtools root>")"`, then `sed -i "s|<devtools-root>|$MOUNT_NAME|g" "$KAIZEN_ROOT/README.md"` (both the canonical-guide link and the quick-link carry it). Verify the link resolves from `<kaizen root>/README.md` before moving on.

---

## Phase 3 — Add the instruction-file pointer

The project's root instruction file — `AGENTS.md`, or where a repository has none, its existing root instruction file, whatever it is called — should orient future sessions to kaizen. Never create an instruction file to hold the pointer. If it has no kaizen section, add one near the top (after the project overview). Keep it short and point to the canonical guide rather than restating it:

```markdown
## Kaizen journal

We practice continuous improvement. The [kaizen journal](./docs/work/kaizen/journal/) records friction in **how we build** — the collaboration loops between humans, AI agents, and tooling — so we can iteratively improve our process, one entry per file. The [patterns](./docs/work/kaizen/patterns/) distill recurring themes into actionable changes. Methodology: [`<MOUNT_NAME>/docs/kaizen-guide.md`](./<MOUNT_NAME>/docs/kaizen-guide.md).

**Scope: kaizen is about the *way* we work, not the *thing* we build.** Process friction goes in the journal; feature ideas do not. When you hit friction (unexpected errors, multiple attempts, a misread instruction), add a journal entry. Run the session-end skill to capture a session's friction before it evaporates.
```

(`<MOUNT_NAME>` is `basename "<devtools root>"` from Phase 1 — the name this project mounts the tree by; `devtools/` in the fleet layout, `workshop/` for a mirror consumer.)

If a kaizen section already exists, leave it and note that in the report.

---

## Phase 4 — Optional: index entry

If the project has a docs index (`docs/README.md`), you may add a one-line entry linking the kaizen root — `docs/work/kaizen/`. Index entries are optional human-facing curation; if one exists it must stay accurate. If the project has no docs index, skip this.

---

## Phase 5 — Report

Print a concise summary:

- **Created** — which of `README.md` / `journal/README.md` / `patterns/README.md` were newly created (vs. already present), and whether an existing single-file journal was converted.
- **Instruction file** — section added, or already present.
- **Index entry** — curation entry added, or n/a.
- **Next step** — tell the user the system is live: capture friction with the `session-end` skill, and run a `patterns/` review every ~2 weeks (per the guide). Do not commit automatically — surface the new files and let the user commit.

Do **not** push or auto-commit.
