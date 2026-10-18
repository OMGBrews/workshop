# Consumed by

The superproject that records this repository as a submodule tracking `main`, and why a
merged change here is not the end of the job. The machine-readable list between the
sentinels is what a `ship` skill parses; the prose is for whoever has to decide what to do
about a lagging pointer.

<!-- CONSUMED-BY:BEGIN — DO NOT REMOVE: /ship parses the parent list between these sentinels. -->
OMGBrews/workshop-dev
<!-- CONSUMED-BY:END -->

## Why exactly one line, when many repositories mount this one

`OMGBrews/workshop-dev` is the private maintainer wrapper. It nests this repository at
`workshop/` and is the only consumer that declares the edge with `branch = main`, which is
what puts it on the list: the declaration answers *"whose recorded pointer should move when
a change lands here"*, and a tracked edge is the only kind anyone is expected to move
promptly.

Every other consumer — the whole OMG Brews fleet, plus any outside project that vendors
this repository — mounts it **pinned**, with no `branch` key. That is deliberate and is the
normal state: nothing propagates to a pinned consumer until someone there commits a new
pointer, so a pinned edge has no owed bump and belongs on no list. Adding those consumers
here would turn a short, actionable list into an inventory that is wrong the moment a repo
is added or removed, and would ask for pointer bumps nobody agreed to take.

A lagging pointer is expected and safe. An *unrecorded* one is invisible, which is the
failure this file exists to prevent.

## What the wrapper's pointer owes

The wrapper's edge is guarded by required CI on its own `main`: the recorded gitlink must be
reachable from this repository's `main` and must never move backwards. The practical
consequence for a change landing here is the ordering — **merge here first, then bump the
pointer to the post-merge SHA, and open the wrapper's pull request only after that, with its
checks rerun against the new pointer.** A pre-merge PR-branch SHA passes locally, because the object
is in the local clone, and is orphaned by the squash merge that lands it; the wrapper's
pointer check refuses it rather than letting a fresh clone fail on a submodule fetch. A wrapper pull request
opened earlier would be tested against the old pointer and start red on any wrapper edit that
needs this change — the dependent-parent case `/ship` defers.
