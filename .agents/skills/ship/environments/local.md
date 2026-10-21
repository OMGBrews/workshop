# Ship policy — `local` (bundled default)

The default for a repository that declares no `docs/work/ship/local.md`. It
restates the fleet's shipping convention for an authorized local session
(Workshop `docs/shipping-conventions.md`): where the default branch permits it,
commit and push directly. A repository with different rules writes its own file
and says why.

## Route

`direct`.

## Target branch

The branch currently checked out, which is normally the default branch. Before
landing: `git fetch origin`, then rebase only unpublished local commits onto `origin/<default>`
on a clean tree; merge upstream into a branch already published, then `git submodule update`. A branch that is not the default
branch lands on itself; moving it onto the default branch is a separate,
explicit instruction.

## Merge authorization

Not applicable on a direct route. The invocation authorizes the commit of this
session's files and the push of this session's commits to the target branch,
and nothing else: no branch, worktree, or PR is created by default, and a
commit another session made and has not pushed is not published unasked.

## Monitoring

None owed. CI runs after the push and the ship does not wait on it; the report
names the pushed SHA so the run can be found. A red run afterwards is ordinary
work, not a ship failure.

## Environment-limited checks

None by default. Every row of the definition of done is expected to run on a
local machine; a repository whose local environment lacks something (a secret,
a licensed tool, a host service) names it in its own policy file.

## Submodules

A pinned edge (no `branch =` in `.gitmodules`) is never bumped by a ship; a
dirty or advanced checkout under one is a stop, because that work belongs in
the submodule's own repository and lands there first. A tracked edge
(`branch = <name>`) is bumped child-first per the skill's submodule reference.

## Report

Nothing beyond the invariant lines.
