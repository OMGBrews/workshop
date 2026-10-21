# Ship reference — submodules and declared parents

Loaded by the `ship` skill only when a repository in the plan carries a
`.gitmodules` edge with `branch =`, or a `docs/work/consumed-by.md`. A
repository with neither has no parent work and never reads this file.

## Two classes of edge, one of them this skill's to bump

The discriminator is the `branch` key in the parent's `.gitmodules`, never the
directory name.

- **Composition** (`branch = main`): a superproject and a real component of it.
  A component can have more than one parent, so a parent list is a list. A
  stale pointer here presents an old component as current. The ship bumps
  these by default, child-first.
- **Distribution** (no `branch` key, pinned): a shared tree mounted by many
  consumers. The ship never bumps one. A lagging pin is the expected state, and
  moving it is the consumer's deliberate act, not a ship's side effect.

## Inventory without a remote

Behind the cloud proxy, `git -C <sm> fetch origin` fails for an unattached
repository. The question "does this checkout carry work nobody pushed" is
still answerable: a clean checkout sitting exactly on the recorded gitlink
cannot carry work this session created.

```bash
if git -C "$sm" fetch origin 2>/dev/null; then
  git -C "$sm" log --oneline "origin/$default..HEAD"          # authoritative
else
  recorded="$(git rev-parse ":$sm" 2>/dev/null || git ls-tree HEAD "$sm" | awk '{print $3}')"
  if [ -z "$(git -C "$sm" status --porcelain)" ] && [ "$(git -C "$sm" rev-parse HEAD)" = "$recorded" ]; then
    echo "$sm: no unshipped work (verified without a remote: clean, HEAD == recorded gitlink)"
  else
    echo "$sm: UNKNOWN — fetch failed and the checkout has moved or is dirty" >&2
  fi
fi
```

Say which branch ran. The fallback says this session introduced nothing, not
that the recorded pointer is current. `UNKNOWN` is a stop. Do not skip pinned
edges in the inventory: a pin suppresses pointer movement only, and editing a
mounted shared tree from inside a consumer is a normal way changes reach it.

## Declared parents

A child cannot discover its parents from its own metadata; the edge is recorded
only in the parent. The declaration is `docs/work/consumed-by.md`:

```bash
f="<repo>/docs/work/consumed-by.md"
if [ ! -f "$f" ]; then echo "no declared parents"; else
  decl="$(awk '/^<!-- CONSUMED-BY:END/{exit} p && NF; /^<!-- CONSUMED-BY:BEGIN/{p=1}' "$f")"
  bad="$(printf '%s\n' "$decl" | grep -Evx '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' || true)"
fi
```

The sentinel patterns are anchored to the start of a line, so prose that quotes
a sentinel cannot open the block; `exit` on the first END keeps a later pair
from reopening it. Three outcomes:

- **No file** → no declared parents. Not an error.
- **File present, `$decl` empty** → a broken declaration. Report it as broken;
  it is not "no parents".
- **`owner/repo` lines** → one pointer-bump entry per line, unless this session
  already mounts the child inside that parent. A non-empty `$bad` is malformed
  and stops the plan.

Recognize a declared parent among the session's repositories by running
**both** sides through `<mount>/Tools/normalize-remote.sh` and comparing; it
lowercases, matches the trailing `owner/repo` pair under every URL shape
including the cloud proxy's, and exits non-zero on input it cannot reduce.
Read its exit code.

**The plan closes transitively**: a parent that receives a bump is itself a
repository that ships, so read its declaration and repeat until nothing new
appears.

**Docs-only ships flip the default**: when everything a repository ships is
docs-only per its predicate, plan a named lag notice per parent instead of a
bump PR, and let the maintainer ask for the bump.

## Child-first cycle (direct route)

1. Publish the child's authorized commits, then fetch and prove the selected
   child SHA is reachable from its remote default branch. A push to another
   branch is not enough to advance a parent pointer.
2. Resolve each tracked parent's environment, policy, ownership of local
   changes, and required checks independently. A pinned edge stays pinned.
   Locate absent parents using the declared-parent procedure below; attach
   through a harness tool only when that environment requires it.
3. In a clean child checkout, check out the verified SHA and record that
   gitlink in the parent along with any documented companion edits. Restore
   other child checkouts to their recorded gitlinks and check the exact parent
   candidate. Never overwrite foreign work to create a clean checkout.
4. For a direct parent, commit and push only authorized session work, prove
   containment on its remote default branch, then repeat upward. For a PR
   parent, push and open its checked candidate, apply its own merge policy,
   and stop the upward cycle until it merges. Report pending parents with
   both pointer SHAs. Child authorization never grants parent authorization.

## Child-first merge cycle (pull-request route)

Bottom-up. An intermediate repository takes both roles: it receives its
children's bumps before it merges in its own turn.

1. **Child first.** Required checks green and the merge authorized per the
   policy file. Merge (squash). Capture the merge SHA from the response.
2. **Verify before recording**: `git -C <sm> fetch origin`, then
   `git -C <sm> merge-base --is-ancestor <merge-sha> origin/<default>`, exit 0
   or stop.
3. **Record the pointer**: `git -C <sm> checkout <merge-sha>`, then
   `git add <sm>` and commit (`Bump <name> pointer: <what the child PR did>`).
   Run any post-bump step the superproject documents (for a Workshop bump,
   `<mount>/Tools/sync-skill-symlinks.sh .`) in the same commit.
4. Resolve the parent's own environment, route, and authorization before
   choosing how to land its pointer. Restore all child checkouts to the
   gitlinks the parent now records, then rerun the parent's applicable checks.
   A direct parent follows the direct cycle above: commit, push, prove, and
   continue upward only after its default branch contains the result.
5. **PR parent last.** For a pull-request parent, push only after its local
   checks pass. If deferred, open its PR now, cross-link it, and arm its return
   path; otherwise update the existing PR. Wait for required PR checks and
   merge (squash) only under that parent's own authorization. Otherwise report
   the open PR, both pointer SHAs, and pending higher parents; stop upward here.
6. **Prove the end state**: per shipped submodule, the gitlink recorded on
   `origin/<default>` is reachable from that submodule's `origin/<default>`,
   and the superproject's `origin/<default>` contains the merge SHA. Print both
   SHAs and the number of gitlinks inspected. `gitlinks inspected: 0` is said
   in those words, never as a bare pass: a ship with no submodule work passes
   the per-submodule assertion vacuously, and only the containment line proves
   anything.

**Pull-request route, open PRs**: after pushing a submodule's branch, restore
its checkout to the recorded pointer (`git submodule update --checkout <sm>`
from the superproject) so the superproject tree is clean during review instead
of showing gitlink drift. Never silence that drift by committing it.

## The unattached parent

A declared parent this session does not mount. Runs **after** the child has
landed on its default branch, by direct push or merge, never before.

1. In a harness that requires attachment, attach it (`add_repo <owner>/<repo>`).
   Otherwise use the existing authenticated Git transport. Check access and
   report a failure as a pending parent.
2. Clone it **outside** the child's working tree:

   ```bash
   parent="${TMPDIR:-/tmp}/<parent-repo>"
   git clone https://github.com/<owner>/<parent-repo>.git "$parent"
   ```

   Read the parent's instructions and resolve its own environment and policy.
   For a PR route, create the policy's branch before editing; for a direct
   route, retain its declared target branch. Do not force the child's route
   or authorization onto the parent.

3. Find the submodule path by matching the child's clone URL in the parent's
   `.gitmodules`, never by guessing the directory name:

   ```bash
   # sm_path, never `path`: in zsh, lowercase `path` is tied to PATH.
   sm_path="$(git config -f "$parent/.gitmodules" --get-regexp '^submodule\..*\.url$' \
     | grep -iE "[:/]<owner>/<child>(\.git)?$" \
     | sed -E 's/^submodule\.(.*)\.url .*/\1/' \
     | while read -r n; do git config -f "$parent/.gitmodules" "submodule.$n.path"; done)"
   ```

   Test `$sm_path`, never `$?`: a no-match leaves the loop's status at 0. Empty
   means the declaration and the parent disagree; more than one line means the
   parent mounts the child twice. Both stop.
4. Containment check in the child checkout this session already has, then
   record the pointer in the parent: `git -C "$parent" submodule update --init
   -- "$sm_path"`, fetch, `checkout <landed-sha>`, `git -C "$parent" add
   "$sm_path"`. When the parent's checkout cannot fetch the child,
   `git -C "$parent" update-index --cacheinfo 160000,<landed-sha>,"$sm_path"`
   stages the gitlink, and the containment check is then the only thing between
   you and a dangling pointer.
5. Run the parent's checks against the recorded gitlink, then follow its
   route: direct commit/push/proof, or commit/push/PR with cross-links and its
   return path. Unavailable required local evidence stops this step; a gitlink staged without a checkout
   cannot stand in for a check that reads that child.
6. Authorization follows the **parent's** policy; the child's authorization
   does not carry. After a direct parent lands and is proved, repeat upward.
   For a PR parent, merge only when its own policy permits it. A review-pending end state is:
   child landed, parent PR open, parent's default branch still recording the pre-merge pointer.
   Report it by name and by both SHAs.

A parent that is attached but does not mount the child skips steps 1 and 2.
A declined or blocked parent is reported as pending with both SHAs, never as
done; nothing catches a lag up on its own.

## Gitlink conflict on rebase

Keep the SHA that is later on the submodule's default branch:
`git -C <sm> fetch origin`, `git -C <sm> merge-base --is-ancestor <A> <B>`
(exit 0 means B is later), `git add <sm>`, continue, `git submodule update`.
Resolving to the earlier SHA moves the pointer backwards while a reachability
check stays green.
