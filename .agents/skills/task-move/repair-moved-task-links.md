# Repair links when tasks move

`task-move` and `task-reprioritize` use this procedure around their file moves.
It preserves inbound references and the intended destinations of links inside
moved briefs, with or without repository-local repair tooling.

## Before the moves

1. Inspect `git status --short` and the staged diff. Record pre-existing edits
   and staging so they cannot be swept into this operation. Preflight every
   source and destination for collisions; stop before overwriting anything.
2. **Check for existing tooling first:** read the repository's instructions,
   definition of done, and script/check configuration for a Markdown-link repair
   and a link check. Inspect their interfaces and exclusions before use. A
   consumer may supply `scripts/repair_doc_links.py <old-path> <new-path>`;
   that name and interface are an example, not a dependency. Prefer an available
   mechanical repair to a hand sweep. Missing optional tooling needs no warning
   and does not require installing or introducing a replacement.
3. Record the **complete old/new repository-relative path map**, even for a
   single move. Save each source brief's pre-move content outside the repository
   and inventory its active relative link destinations: source occurrence,
   original destination, resolved intended file, and query/fragment suffix.
   Include images and reference definitions. Resolve against the **old** source
   directory, using the repository's link semantics and documented exclusions.
   Keep code examples, external URLs, fragment-only links, and excluded or
   immutable historical citations unchanged according to that policy. Inspect
   repository-root links too if the local checker supports them.
4. Discover inbound live references across the repository, including untracked
   documents relevant to this operation. Search each old path and task slug
   (for example, `rg -n --hidden -F '<task-slug>'` with explicit exclusions for
   Git metadata and vendored trees). Confirm the search covers the repository's
   document sources, including any ignored sources its policy makes relevant.
   Read matches: a longer slug, code example, or historical citation need not
   be a live link. Inspect relative destinations too; text searches alone can
   miss reference definitions, encoded paths, and differently spelled links.
5. **Preflight journal citations before any move or mechanical repair.** Journal
   entries cite task briefs, problem records, and patterns by backticked slug,
   with type and repository where needed; these citations stay unchanged. A
   legacy journal link to a moved brief requires the kaizen guide's *Journal
   citations and one-time adoption* procedure as a separate recorded migration
   before the move. Resolve the guide through the mounted Workshop distribution
   or the project's kaizen README; unavailable or conflicting policy stops
   adoption. Name the affected entries and defer the move until it is complete.
   Do not use routine link repair to edit immutable entries or weaken the
   whole-tree check with exclusions. Links to journal evidence remain protected.

If an intended target or an overlapping pre-existing edit cannot be resolved
confidently, stop and report it before moving. Do not guess from what happens
to exist at the destination.

## After all moves, before reporting success

1. Complete the caller's planned moves, then repair inbound links for **each**
   old/new pair in one repair phase. Use the discovered mechanical repair with
   its inspected interface, ensuring immutable journals are not rewritten; read
   its complete output and exit status. Without
   one, repair the discovered live references manually. Preserve link style,
   titles, escaping, query strings, fragments, and documented exclusions.
   Inspect the diff and discovered references even when a script reports no
   changes; its scope may omit an affected document.
2. **Restore moved briefs' outbound links last, from the pre-move inventory.**
   For each original intended file, apply the full move map once to find its
   final location, then express that target relative to the brief's new
   directory. A target not in the map stays at its original location. This
   covers sibling links, links between two moved briefs, and self-links;
   mapping once avoids cascading through another pair's old path. Preserve
   suffixes and exclusions. Correct any incidental rewrites the inbound tool
   made while scanning other moved briefs. Do not restore entire snapshots over
   other intended edits: change the affected link destinations only.
3. Compare every affected link's final resolved destination with its recorded
   intended target, mapped to the final location. **Existence alone is not
   enough:** an unrepaired sibling link can resolve to an existing but wrong
   file. Revisit the inbound discovery to confirm all live references were
   handled, and report any preserved historical citations as such.
4. Stage the renames and all associated repairs together, using explicit paths
   or selected hunks. Include any changed paths printed by the repair tool
   after reviewing them. Never use blanket `git add .` or stage unrelated
   changes. Inspect `git diff --cached` against the starting staged state;
   where unrelated hunks share a file, preserve their index/worktree state.
5. Run the repository's **existing link check against the complete resulting
   tree**, after staging so tracked-file checks see new paths. Run any other
   applicable repository requirements. If no link check exists, inspect all
   affected references and intended targets directly; this is manual
   verification, and requires no new tooling.

An available repair script or required link check that fails or errors stops
the operation. An unresolved reference also stops it before committing. Report
the command, exit status, or unresolved paths, leaving changes available for
inspection; do not report success, offer a commit, retry by hand to conceal a
tool failure, or weaken the check. Missing optional tooling is not an error.

On success, report the moves, repaired files, and verification result (manual
when applicable). Return to the caller's authorization rules: this procedure
stages work and grants no commit or shipping permission.

The [verification walkthrough](link-repair-verification.md) exercises these
steps with mechanical repair, manual fallback, co-moved targets, and failures.
