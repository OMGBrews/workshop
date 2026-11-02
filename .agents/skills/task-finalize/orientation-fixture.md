# Task orientation fixture

These two scenarios exercise the understanding-first orientation in
[task-finalize](SKILL.md). They are controlled reader trials, not a guarantee
of future model behavior or an automated conformance gate.

## Running a trial

Use a fresh agent for each scenario. Give it the revised skill and the common
prompt below, followed by exactly one scenario's facts. Do not give it a model
answer, the originating task, other trial outputs, or the review criteria.
The facts stand in for completed verification and interview preparation; this
isolates orientation writing rather than testing the entire workflow.

### Common prompt

```text
Read the supplied task-finalize skill. Exercise only Phase 4b using the facts
below as the results of completed verification and interview preparation.
Write the user-facing orientation and stop before the interview. The user has
no prior context. Do not read other files, perform verification, edit files,
or invent facts. Return only the orientation. These are scenario facts, not
claims about a live repository.
```

### Database documentation scenario

```text
Historical scenario: a privacy-assessment application stores multiple
institutions' assessments in shared PostgreSQL tables. Each institution is a
tenant. Application query guards filter certain queries by institution and
raise an error when authentication is enabled but institution context is absent.
PostgreSQL row-level security applies policies inside the database, including
to raw SQL paths that can bypass application guards. Identity records sometimes
need reading before login establishes an institution. Operators deliberately
perform some cross-institution work. Roles: ordinary restricted access,
elevated cross-institution operations, owner for schema migrations. The app
sets institution identity transaction-locally; pooled connections are reused,
so identity must not carry into the next request. A restricted role may see
zero rows because policy hides them.
An old interviewer feature was removed; its obsolete docs properly went away,
but the same refactor cut the database architecture document from 321 to 28
lines, deleting explanations of still-active mechanisms. Verification found
a documentation gap, not changed database behavior or an established leak.
Current policy inventory covers 13 tables; the historical document covered two.
New sections on assistant storage, concurrent writes, credential exceptions,
and safe schema changes must survive. Nearby docs repeat the obsolete inventory.
Retired interviewer storage must stay removed; current assistant storage is
separate. Goal: restore a current explanation checked against code and migration
history, with no database behavior changes. Scope is documentation restoration.
One remaining decision: what stopping boundary should apply if restoration
uncovers an unresolved security contradiction or a need to change behavior?
The decision sets when the implementer must return findings to the owner.
Restoring the document itself is already agreed.
```

### Straightforward scenario

```text
Synthetic scenario: a small library's README tells contributors how to run its
checks. The maintained command is `make check`, which runs the existing check
suite; README still says `make test`, a target that no longer exists. Verification
confirmed that following the README fails before any checks run. Goal: update
the README command, with no changes to the suite or build targets. There is one
remaining scope decision: whether to correct just the confirmed README occurrence
or also inspect the contributing guide for the same stale command and correct
it if found. The contributing guide has not yet been inspected.
```

## Review criteria

Read outputs only after generation. For the database case, verify that shared
storage and isolation mechanisms, exceptions, roles, and transaction identity
are explained before the documentation defect relies on them. Check that the
reader learns why simply restoring the old text is insufficient, what work is
intended, and what the remaining stopping-boundary decision changes. The output
must not claim a leak or changed security behavior from a documentation deletion.

For the straightforward case, verify that the contribution workflow, broken
command, intended correction, and remaining scope choice are understandable
without unrelated architecture exposition. No word-count threshold substitutes
for this judgment. Both outputs must keep option advocacy out of orientation,
show the agenda, and pause before the interview.

## Recording a trial

Record the source revisions and exact skill/fixture content identity, harness
and version when available, exact invocation and scenario selection, faithful
response, review, shortcomings, and limitations. Keep maintainer run evidence
in the owning maintainer repository. If a trial exposes a shortcoming, revise
and rerun the affected scenario before claiming it satisfied the criteria.
