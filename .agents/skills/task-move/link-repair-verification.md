# Task move link-repair verification

This records an authoring walkthrough of
[the shared procedure](repair-moved-task-links.md) in disposable Git
repositories. The commands and assertions exercised the instructed operations;
they are not an automated execution test of an agent reading the skill.

## Fixture and intended targets

Start with committed Markdown and two planned moves:

| Original file | Final file |
|---|---|
| `docs/work/tasks/now/a.md` | `docs/work/tasks/soon/a.md` |
| `docs/work/tasks/now/b.md` | `docs/work/tasks/later/b.md` |

Create both `now/guide.md` (the intended guide) and `soon/guide.md` (a different
existing file). The latter makes an unrepaired sibling link look valid to an
existence checker. Add an image at `assets/pixel.png`.

Record these links before moving, then require these exact final destinations:

| Source | Original destination | Required final destination |
|---|---|---|
| Root `README.md` | `docs/work/tasks/now/a.md?view=full#goal` | `docs/work/tasks/soon/a.md?view=full#goal` |
| Root `README.md` | `docs/work/tasks/now/b.md#goal` | `docs/work/tasks/later/b.md#goal` |
| `a.md` | `guide.md?view=full#part` with title `"Guide"` | `../now/guide.md?view=full#part` with the same title |
| `a.md` | `b.md#goal` | `../later/b.md#goal` |
| `b.md` | `a.md#goal` | `../soon/a.md#goal` |
| `a.md` | `a.md#goal` | `a.md#goal` |
| Image in `a.md` | `../../../../assets/pixel.png` | Unchanged |
| Reference definition in `a.md` | `guide.md#part` | `../now/guide.md#part` |
| Inline-code example in `a.md` | `[example](missing.md)` | Unchanged code bytes |

Also create an **untracked** root `notes.md` linking to
`docs/work/tasks/now/a.md#goal`, and stage an unrelated change to
`unrelated.txt`. The note must be repaired to the new path; the unrelated
staging must survive and stay out of the move commit.

## Mechanical-repair walkthrough

The run used the reporting consumer's existing stdlib Python repair and checker
in the disposable repository, without modifying their interfaces. Inspected
source fingerprints (SHA-256) were:

```text
repair_doc_links.py cc7af46111dbf67fe38900f43b405b811bab6f65a1186c3d16550dcb2e73fa10
check_doc_links.py 95aa89b646e6a80a97f8acdaace8fe9dd67f605e4add33be60083913fa631432
```

After capturing the source content and intended destinations, run both
`git mv` operations. Invoke the existing repair once per pair:

```bash
python3 scripts/repair_doc_links.py docs/work/tasks/now/a.md docs/work/tasks/soon/a.md
python3 scripts/repair_doc_links.py docs/work/tasks/now/b.md docs/work/tasks/later/b.md
```

Both returned 0, each printed `README.md`, and each reported one rewritten link.
The tool scans tracked files, so it omitted `notes.md`; repair that discovered
reference manually. Restore the moved briefs' link destinations from the saved
inventory using the full map. Assert exact destination bytes, suffixes, title,
and preserved example bytes, and resolve the guide and peer links against their
recorded intended files. The wrong guide exists, so asserting the guide's
identity is necessary.

Stage the four affected destination files explicitly: `README.md`, `notes.md`,
`docs/work/tasks/soon/a.md`, and `docs/work/tasks/later/b.md`. The index then
contained the two renames, both inbound repairs, and the pre-existing unrelated
staging. The **first** post-repair whole-tree check returned 0:

```text
$ python3 scripts/check_doc_links.py
All markdown links resolve (6 files checked).
```

A fixture pre-commit hook ran that same whole-tree checker. The first move
commit attempt returned 0, with exactly one hook invocation. Inspecting
`git show --format= --name-only --no-renames HEAD` confirmed that both old and
new task paths, `README.md`, and `notes.md` were in that one commit.
`git diff --cached --name-only` then contained only `unrelated.txt`.

## No optional tools

Repeat the fixture without repair scripts, a link checker, or hooks. Perform
the same discovery, pre-move capture, moves, and manual destination edits.
Inspect all affected destinations against the table, including the guide's
identity and preserved suffixes. This run matched the expected contents and
targets, staged all repairs, and recorded them with both renames in one fixture
commit. The unrelated change remained staged. No missing-tool warning or new
repository tooling was needed. This is manual reference verification, not a
passing repository link check.

## Failure branches

Two separate fixtures followed the procedure's stop branch:

- An available repair command printed `injected-repair-failure` and exited 7
  after the moves. The walkthrough stopped without a manual fallback, check,
  or commit. `git rev-parse HEAD` stayed unchanged and moved files remained
  available for inspection.
- The real whole-tree checker found an additional tracked
  `[unrelated existing flaw](missing.md)` reference and exited 1, naming
  `broken.md` and `missing.md`. The walkthrough stopped without committing or
  suppressing the reference. `HEAD` stayed unchanged; staged moves and repairs
  remained available for inspection.

These observations show the documented operations and stopping conditions are
usable. They do not prove how every future agent or consumer-specific parser
will behave; consumers must still inspect their tooling's scope and semantics.
