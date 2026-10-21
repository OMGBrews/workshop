# Ship reference — a working tree shared by several sessions

Loaded by the `ship` skill whenever the inventory finds changes this session
did not make. On a local machine several agent sessions commonly work in the
same checkout at once, so `git status` shows the union of everyone's work, the
index may hold another session's staged files, and the branch may carry
another session's unpushed commits. Every procedure here was exercised in a
scratch repository on 2026-10-20 (git 2.52); the refusal cases were exercised
too.

## The rule

**Commit only what this session changed. Touch nothing else.** The session's
own record of the files it wrote, edited, generated, or deleted in this
conversation is the source of truth. `git status` is a cross-check, never the
list. When the record is incomplete (a context summary dropped it), every path
not in the record is foreign.

## Classify every dirty path

For each line of `git status --porcelain=v1 -z`, decide:

- **Mine** — in the session's record. Ships.
- **Foreign** — not in the record. Left exactly as found: not staged, not
  committed, not formatted, not reverted, not stashed. Named in the report by
  path, under "left for another session".
- **Shared** — in the record, but `git diff -- <path>` shows hunks this
  session did not write. **Stop.** A file two sessions edited cannot be split
  safely by a ship; put it to the user with the hunks named.
- **Generated** — produced by a generator this session ran (TypeScript
  sections, the reference library, `.env.example`). Mine, and said so.

Check the index separately: `git diff --cached --name-only` minus the session's
paths is **foreign staged** work. The pathspec commit below leaves it staged.

## Commit by pathspec, never by index

```bash
git add -N -- <new files>                      # intent-to-add: lets a pathspec commit see new paths
git commit -m "<message>" -- <every session path>
git show --stat --format= HEAD                 # must list exactly the session's paths
```

A pathspec commit builds a temporary index from the named paths' working-tree
contents, so another session's staged entries stay staged and its unstaged
edits stay in place. Deleted files are named in the pathspec too. Never an
unscoped `git add -A`, `git add .`, `git add -u`, or `git commit -a`: each
sweeps in foreign work.

**When a path changed type** (a symlink replaced by a directory, a file by a
symlink), a pathspec commit fails with `fatal: updating files failed` after
`error: '<path>' does not have a commit checked out`, because the entry in
`HEAD` and the thing on disk cannot both be expressed. Commit through an
explicit temporary index instead; the pathspec on `add -A` scopes it to the
session's paths, and nothing else in the real index is read or written:

```bash
tmp="$(mktemp)"
GIT_INDEX_FILE="$tmp" git read-tree HEAD
GIT_INDEX_FILE="$tmp" git add -A -- <every session path>
GIT_INDEX_FILE="$tmp" git commit -m "<message>"
rm -f "$tmp"
git reset -q -- <every session path>       # refresh the real index for those paths only
git show --stat --format= HEAD             # exactly the session's paths, or stop
```

Verified 2026-10-20: with another session's file staged, the commit held
exactly the session's paths and the foreign file was still staged afterwards.

**The commit hook and foreign unstaged changes.** Inspect the repository's
hooks before committing. A hook that stashes unstaged changes removes another
session's edits from disk while it runs; a concurrent write may be lost or
conflict on restoration. Formatters that touch foreign staged files have the
same ownership problem.

When foreign changes exist, use the repository's documented safe check-mode
equivalent. Its policy file's `## Report` heading names the stand-in command,
any additional required steps, and whether bypassing the mutating hook is
authorized. Run every applicable requirement; do not infer that foreign-file
failures may be ignored. If no safe equivalent is documented, or required
evidence fails, stop and report the missing procedure or failure. Do not invent
a bypass. Where authorized, commit with `--no-verify` only after that evidence
passes, and report both the bypass and the exact steps that replaced the hook.

Check for foreign unstaged changes in the same shell command immediately before
the commit. This narrows the race but does not lock other sessions out; if the
hook can still mutate their files, use the documented safe route. Never run a
formatter that changes foreign staged files merely because a hook invokes it.

## Integrate upstream without touching the tree

If `git merge-base --is-ancestor origin/<default> HEAD` exits 0 the branch is
ahead and no integration is needed. Otherwise the session's commits must be
replayed onto the moved default branch, and `git rebase` refuses on a dirty
tree while `--autostash` reverts foreign files for the rebase's duration. Use a
temporary worktree instead:

```bash
tip="$(git rev-parse HEAD)"                     # capture here: inside the worktree, HEAD is origin/<default>
base="$(git merge-base "$tip" origin/<default>)"
wt="$(mktemp -d)"
git -c submodule.recurse=false worktree add --detach "$wt" origin/<default>
git -C "$wt" -c submodule.recurse=false cherry-pick "$base..$tip"   # conflicts: resolve in $wt, or abort and report
new="$(git -C "$wt" rev-parse HEAD)"
git -c submodule.recurse=false worktree remove "$wt"
git -c submodule.recurse=false read-tree -m -u HEAD "$new" && git reset --soft "$new"
```

Two details are load-bearing, both found live on 2026-10-20. The range names
`$tip`, never `HEAD`: a `git -C "$wt"` command resolves `HEAD` in the worktree,
where it is `origin/<default>`, so `$base..HEAD` replays the upstream commits
onto themselves and "conflicts" on files nothing local touched. And
`submodule.recurse=false` on every worktree command: a repository that sets
`submodule.recurse=true` makes cherry-pick and checkout try to update the
submodule in the worktree, which has no module directory, and the operation
dies with `could not reset submodule index` half-applied.

`read-tree -m -u` updates only paths that differ between the old and new
commits, keeps every other index entry including foreign staged ones, and
**fails with `Entry '<path>' not uptodate. Cannot merge.`** when such a path
has local changes. That failure is the design: upstream changed a file another
session is editing, and the ship stops and names the file rather than
overwriting it. `reset --soft` then moves the branch without touching the
index or tree. Afterwards re-run the checks the incoming commits could affect,
and `git submodule update` only if a gitlink moved and that submodule's
checkout is clean.

## Push only this session's commits

`git push origin <branch>` publishes every unpushed commit on the branch,
including ones another session made and has not pushed. Before pushing, list
them:

```bash
git log --format='%h %s' origin/<default>..HEAD
```

Every commit must be one this session made, by its own record. A foreign
commit in the range stops the ship: another session may still be verifying it,
and publishing it is their call. Report the commits and ask, and ask **before**
integrating upstream, because the worktree replay above rewrites every commit
in the range and would mint new SHAs for the foreign ones too. When the foreign
commits are **below** the session's, the session's cannot be pushed alone;
when they are above, the session's can be pushed by SHA
(`git push origin <session-tip>:<branch>`) only if the branch then still
fast-forwards, provided the remote target is an ancestor of that session tip. The foreign
commit stays local; do not move or rewrite the shared branch to do this. Either way
the answer is the user's.

## Never, in a shared tree

- `git stash` in any form, including `rebase --autostash` and `pull --rebase`
  on a dirty tree.
- `git checkout -- .`, `git restore .`, `git reset --hard`, `git clean`.
- `git switch` or `git checkout <branch>`: changing the checked-out branch
  rewrites every file under every session.
- `git add -A`, `git add .`, `git add -u`, `git commit -a`.
- A whole-tree formatter or fixer in write mode.
- Deleting or moving a file the session did not create.
