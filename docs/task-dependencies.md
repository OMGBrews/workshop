# Task dependency checks

Workshop provides a read-only check for a consumer repository's task graph.
It detects dangling or ambiguous prerequisites; task auditing separately decides
whether history proves that a missing prerequisite was completed.

From a consuming repository, run:

```bash
bash workshop/Tools/check-task-dependencies.sh "$PWD"
```

Pass the repository root explicitly. Exit 0 means all inspected dependency slugs
resolve uniquely; exit 1 reports malformed dependency fields, missing targets,
or duplicate filename slugs. Exit 2 reports invalid or unavailable input,
including a missing tasks root. An existing empty tree passes with an explicit
zero-brief count. Every verdict reports the number of briefs and edges inspected.

The inventory includes Markdown task files recursively under `now/`, `soon/`,
`later/`, `finalized/`, `parked/`, and legacy `queued/`. `README.md`,
`_TEMPLATE.md`, and `focus.md` are excluded as both sources and targets. Slugs
are exact filenames without `.md`; directory placement does not affect matching.
Legacy briefs are labelled for recovery and inspected without modifying them.
This command changes no files and makes no completion decisions.

Dependency syntax is shared with
[`check-task-readiness.sh`](../.agents/skills/task-finalize/check-task-readiness.sh)
through its `--dependencies <task-file>` mode: one frontmatter `dependencies:`
field containing an inline or block list of kebab-case slugs, with optional
quotes and comments. An empty list is `dependencies: []`. The dependency-only
mode validates frontmatter and dependency syntax and prints one slug per line;
it does not require the other readiness fields or resolve targets. Existing
readiness warnings and conformance policy remain unchanged.

Use [`task-audit`](../.agents/skills/task-audit/SKILL.md) to investigate missing
slugs. Only completion proven by the removed brief's acceptance evidence and
implementation history permits automatic removal. Typos, renames, rejection,
consolidation, and unavailable history remain for review. Repairs preserve the
dependent's other prerequisites, metadata, and bucket; an empty prerequisite
list does not automatically change status. Rerun the checker after repairs.

Consumer gate integration is a repository policy choice. Workshop's `make check`
runs fixture tests of this command, rather than checking a consumer's live queue.
