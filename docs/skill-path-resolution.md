# Resolving devtools-tree paths from skill bodies

A shared skill that reads a document from the tree it ships in must resolve it
by one rule, so the same skill body works in the upstream tree, in a repo that
mounts the tree under any name, and in a vendored copy. This file is the single
source for that rule; a skill body states the rule's one-line essence and cites
this file rather than restating the table.

## The rule

Resolve the target relative to the skill file's **physical** directory — the
directory the file lives in once every symlink on the path to it is followed
(`readlink -f`, or equivalent) — **not** the path a consumer happens to reach
the skill through.

Consuming repos reach a skill through a symlink (e.g.
`.claude/skills/task-create -> ../../workshop/.agents/skills/task-create`
in a repo that mounts the tree as `workshop/`), so resolving
`../../../docs/` **lexically** from the link path lands on the consuming repo's
own `docs/` and misses the document one directory away. Follow the file first,
then take `..`. One rule then covers every layout:

| Layout | Skill lives at | `<skill dir>/../../../docs/<name>.md` resolves to |
|---|---|---|
| Upstream tree | `.agents/skills/<skill>/` | `docs/<name>.md` — hit |
| Submodule or directory mount, any name | `<mount>/.agents/skills/<skill>/` | `<mount>/docs/<name>.md` — hit |
| Vendored copy, no mount | `<repo>/.agents/skills/<skill>/` | `<repo>/docs/<name>.md` — miss, or a genuine local copy |

## Fallback ordering

When the physical-directory path misses, try in order, first hit wins:

1. **Beside the skill first** — the physical-directory path above.
2. **Then the repo-root paths**, kept for repos that mount the docs elsewhere:
   the tree's docs from the repo root — `<mount>/docs/<name>.md`, where
   `<mount>` is the name *this* repo mounts the tree under — and any repo-root
   file the project keeps that links the document.
3. **Then the no-mount fallback, unchanged**: a per-skill behavior that stays
   working when no mount exists at all — a vendored copy's own `docs/`, a
   documented local substitute, or a degraded run. A skill names its own
   fallback targets; this file names the ordering, not the per-skill list.

**A sibling skill's file** resolves by the same rule one level shallower:
`../<sibling>/<file>` taken from the skill's physical directory hits in every
whole-tree layout, so a fallback only needs to fire for a partial vendored copy
— find the tree by discovery (the `Tools/sync-skill-symlinks.sh` pattern: this
skill's physical location names the mount; where the tree sits outside the
repo, re-derive its basename at the repo root) and say you fell back.

**A command site** — a shell block that invokes a tool from the tree — gets the
same treatment, not path arithmetic on a hardcoded name: resolve the tree root
once from the skill's physical directory and invoke through it:

```bash
DEVTREE_ROOT="$(dirname "$(readlink -f <this skill file as the repo reaches it>)")/../../.."
"$DEVTREE_ROOT/Tools/<tool>.sh"
```

## Disclosure

A run that degrades to a thinner source must be distinguishable from one that
found the real document: **say which source you read, by path**, in the run's
report. A fallback that fires silently is how a class of miss stays unfound.

## Publishing

This file ships with the skills that cite it: `devtools/mirror/manifest.txt`
lists it under "support files the published skills read at runtime", so a
mirror consumer resolves it beside the published skills.
