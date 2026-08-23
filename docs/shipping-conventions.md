# Shipping conventions

How finished code and documentation reach the default branch, in every
repository that follows this file. This is the fleet's single public default
for landing work — read it before the end of any session that produced a
change, so "how does this land?" is never decided fresh.

A repo that needs different rules does not rewrite this document: it names its
own rules in its `docs/work/definition-of-done.md` and says why they differ.
An unwritten divergence is how a fleet ends up with a dozen hand-written
variants of the same convention.

## Run the gates first

A change is finished only after every applicable requirement named by the
repo's `docs/work/definition-of-done.md` has run and passed — scoped by the
surface the change touches, not by category. A repo with no automated gates
simply has no automated command to run; that is an answer, and it changes
nothing else about how the work lands.

## How work lands

Two routes, chosen by where the work happens, not by what the diff contains:

- **From an authorized local session**, where the default branch permits it:
  commit and push directly to the default branch. No branch, no PR — the
  normal flow for work done on a machine the repo trusts.
- **From a cloud session, or a repository that protects its default branch**:
  a pull request is the ordinary way the work lands.

Neither route grants consent by itself. A commit, push, merge, or pull request
is an external action: a user instruction or a standing workflow delegation
must authorize it. "The gate passed" authorizes nothing, and neither does "the
diff is docs-only".

## What a docs-only diff changes

One thing: which gates the change must pass. Nothing else — no new delivery
category, no new authorization.

`Tools/docs-only-diff.sh <base>` — in the repo's own Workshop mount — is the
single classifier, run from the repo root against the diff from `<base>` to
HEAD:

- **Exit 0** — the diff is inside the repo's declared prose surface. Take the
  repo's documented docs lane: skip the gates that, by the repo's own
  declaration, read none of the changed paths.
- **Exit 1 or 2** — not docs-only, or cannot decide. The normal gate path
  applies; exit 2 is never a pass.

The predicate decides gate scoping only. It never decides whether a commit,
push, merge, or pull request is authorized — a docs-only diff still needs the
same consent as any other change. Whether a repo declares a prose surface at
all is its own call, recorded between the `DOCS-ONLY` sentinels in its
`docs/work/definition-of-done.md`; a repo with no declaration gets exit 2,
which is the safe answer rather than a guess made on its behalf.

## Adoption

This file is a standing rule. It reaches a repo through the same pinned
Workshop mount that carries `docs/signal-hygiene.md` and
`docs/definition-of-done.md`, and the short form of the rule lives in that
second document, so adopting a Workshop commit that adds it is the whole
adoption act — no new instruction-file migration. A repo outside the
standing-rule mirror either records a deliberate exception in its own
`docs/work/definition-of-done.md` or follows the same default.

The one repository that cannot import the rules it hosts is Workshop itself,
whose contributor contract is deliberately pull-request-only
(`CONTRIBUTING.md`): every change lands through a reviewed PR. That is the
protected-repository arm of the convention, not a divergence from it.
