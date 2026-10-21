# Ship policy — `cloud` (bundled default)

The default for a repository that declares no `docs/work/ship/cloud.md`. It is
deliberately conservative: a cloud sandbox lands through a pull request, and
merging waits for the maintainer. A repository that wants the session to merge
on its own writes its own file and states the delegation and its reason there,
so no repository inherits an autonomous merge by omission.

## Route

`pull-request`.

## Target branch

The harness-assigned session branch (`claude/...`). A cloud harness pushes
that branch as the session commits, so by ship time it is normally already on
the remote, where a rebase would need a force-push. Bring it current by merging
`origin/<default>` into it on a clean tree, then `git submodule update`; the
squash merge collapses the merge commit. Rebase only a branch the remote has
never seen. The default branch is never a push target from a cloud session.

## Merge authorization

**Stop for review.** Open the PR and stop. Merge only on the maintainer's
explicit go-ahead in the current conversation, or on a later `ship merge`
after they have reviewed. Docs-only classification changes the required
evidence, never merge authorization. A standing delegation must be explicit
in the consuming repository's policy.

## Monitoring

Subscribe to the PR (`subscribe_pr_activity` on the GitHub MCP server): a
merge is delivered to the session in seconds and that is the planned way back.
The subscription does not reliably deliver CI results, so CI state is read
directly (`pull_request_read`, or `gh pr checks`) before any merge. Arm an
insurance timer (`send_later`) only when the subscription is not available;
one per ship, cancelled in the same family when the ship ends. Details:
the skill's `references/cloud-return.md`.

## Environment-limited checks

Unknown for an undeclared repository. State in the PR body which rows of the
definition of done ran in the sandbox and which could not, and never let a
silent skip read as a pass.

## Submodules

A pinned edge (no `branch =` in `.gitmodules`) is never bumped by a ship; a
dirty or advanced checkout under one is a stop. A tracked edge is bumped
child-first per the skill's submodule reference, with the pointer recorded only
to the child's post-merge SHA.

## Report

Close with one line naming who the merge waits on and what is armed to bring
the session back: subscription, timer, both, or neither. "Subscription armed,
no timer" is the expected line, not a gap.
