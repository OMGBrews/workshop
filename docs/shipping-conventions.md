# Shipping conventions

How finished code and documentation land on the default branch in every
repository that follows this file. Read it before the end of a session that
produced a change; the terms used here are defined in
[`verification-terminology.md`](verification-terminology.md).

A repo that needs different rules names them in its
`docs/work/definition-of-done.md` and says why. An unwritten divergence is how
a fleet accumulates hand-written variants of the same convention.

## Gather the required evidence first

A change is ready to land only after every applicable requirement in the
repository's `docs/work/definition-of-done.md` is satisfied, scoped by the
surface the change touches. A repository with no automated checks has no
automated command to run; that truthful answer changes nothing else about how
work lands.

A passing check is evidence. It does not authorize the next action and does not
prove that GitHub or another platform enforces the requirement.

## How work lands

Two routes are standard, chosen by the session and repository rather than by
the diff category:

- **From an authorized local session**, where the default branch permits it:
  commit and push directly to the default branch. The landing requirements are
  procedural unless a platform control also binds that route.
- **From a cloud session, or a repository that protects its default branch**:
  a pull request is the ordinary landing route. Required status checks and
  reviews participate in a platform-enforced landing gate only when the active
  rules bind the branch, actor, and route.

Neither route grants consent by itself. A commit, push, pull request, or merge
is an external action: a user instruction or standing workflow delegation must
authorize it. An approval may satisfy a review requirement without authorizing
every actor to perform the transition. A passing check authorizes nothing.

## What a docs-only diff changes

One thing: which evidence requirements apply. It changes neither the landing
route nor authorization.

`Tools/docs-only-diff.sh <base>` is the shared classifier, run from the repo
root against the diff from `<base>` to `HEAD`:

- **Exit 0** — the diff is inside the repository's declared prose surface. Take
  the documented docs lane and skip only checks proven to read none of the
  changed paths.
- **Exit 1 or 2** — the diff is not docs-only, or applicability could not be
  determined. Take the normal verification path; exit 2 is never a pass.

The classifier selects applicability. It does not provide the evidence that
the selected checks would produce, and it never authorizes an action. A repo
declares its prose surface between `DOCS-ONLY` sentinels in
`docs/work/definition-of-done.md`; no declaration produces exit 2 rather than a
guess.

## Releases and deployments

Shipping changes to the default branch is landing, not releasing. A release
declares an exact versioned candidate or artifact. Publishing, promotion,
deployment, and post-deployment verification are separate actions with their
own requirements and authorization. A repository documents those boundaries
where they exist rather than treating a successful landing check as permission
to cross all of them.

## Adoption

This file is a standing rule delivered by the pinned Workshop mount alongside
`signal-hygiene.md`, `definition-of-done.md`, and
`verification-terminology.md`. A repository outside that instruction contract
records a deliberate exception in its own definition of done or follows the
same default.

Workshop itself cannot import a rule through a submodule it hosts. Its
pull-request-only contributor contract lives in `CONTRIBUTING.md`; that is the
protected-repository route described above, not a different vocabulary.
