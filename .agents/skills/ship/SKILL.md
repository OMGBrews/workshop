---
name: ship
description: Land finished work on the default branch by the route this repository declares for the current environment — a direct push from a local session, or a branch, pull request, CI watch, and merge from a cloud session. Reads the per-environment policy file under docs/work/ship/; bundled defaults cover a repository that declares nothing.
---

# Ship

Turn finished work in this checkout into default-branch state, by whichever
route the repository has declared for the environment the session is running
in. Shipping means **landing**. It does not release, publish, promote, deploy,
or mint any public artifact; those later boundaries keep their own
requirements, authorization, and runbooks.

This skill separates two things that used to share one document:

- **Mechanics** — how to inventory work, prove capability, run checks, land,
  prove the landing, and report. They are the same everywhere and live here.
- **Policy** — which route, which branch, who may merge, how to watch CI, which
  checks this environment cannot run, what the report must say. They differ
  per repository and per environment and live in one short file each:
  `docs/work/ship/<environment>.md`. A repository that declares nothing gets
  the bundled default of the same name from `environments/` beside this file.

**Arguments**: `[local|cloud] [merge]`, all optional. The first word forces the
environment instead of detecting it. `merge` resumes a pull-request route at
the merge step for PRs an earlier run already opened; it is meaningless on a
direct-push route and is reported as such.

## Step 0 — Resolve the environment and its policy

1. **Environment.** Decide in this order and print which signal decided:
   1. the explicit argument;
   2. the repository's location-fact seam, when it has one:
      `bash scripts/lib/harness-signals.sh` prints
      `AGENT_SESSION_EPHEMERAL=<true|false> signal=<variable>`; `true` →
      `cloud`, `false` → `local`, and the plan quotes the line. A nonzero
      exit or malformed result stops shipping; do not fall through to local;
   3. with no seam, `AGENT_SESSION_EPHEMERAL=true` already exported in the
      shell (a harness or wrapper that sets it for the whole session) →
      `cloud`;
   4. otherwise `local`.

   The seam exists because a session-start hook's translation of a vendor
   variable reaches only the process the hook launches: a shell command run
   later never sees it, and on 2026-10-20 a live cloud session read the flag
   as unset and would have taken the local route from a sandbox. Reading a
   vendor variable here directly is not a substitute; the seam owns that
   knowledge. The `origin` URL is not a signal: the cloud git proxy that a
   `local_proxy@` origin once revealed is undocumented and a session has seen
   a plain GitHub origin.

   **A result that contradicts the session's own knowledge is a stop, not a
   tiebreak.** If detection says `local` and the session knows it is in a
   harness-managed sandbox (a harness-assigned branch, a snapshot-restored
   checkout, a documented cloud container), or the reverse, ship nothing; say
   which signal was missing and ask for the explicit argument. The local
   route from a sandbox pushes to the default branch unreviewed, so a guess in
   that direction is the expensive one.

   An environment name is a lowercase word. Only `local` and `cloud` have
   detection rules today; a third environment can be forced by argument once
   a policy file for it exists, and a detection rule for it is a change to
   this step, not to the policy file.

2. **Policy file.** From the repository root, read the first that exists:
   1. `docs/work/ship/<environment>.md` — the repository's own declaration;
   2. `environments/<environment>.md` beside this file, resolved from the
      skill's **physical** directory (`readlink -f` on the path the harness
      reached it by), never lexically from a symlink path.

   Neither exists → stop and report an undeclared environment. Nothing ships.

3. **Validate the policy file.** It carries exactly these seven headings, in
   this order, each answered. A heading with nothing to say says so in one
   line; a missing heading is a malformed policy, and a malformed policy stops
   the ship before any remote action.

   | Heading | Answers |
   |---|---|
   | `## Route` | `direct` (commit and push to the target branch) or `pull-request` (branch, PR, watch, merge). |
   | `## Target branch` | Where the work lands: the default branch, the current branch, or the harness-assigned branch — and how the branch is brought current before landing. |
   | `## Merge authorization` | On a pull-request route: what evidence lets this session merge, or that it must stop for review. On a direct route: what the invocation authorizes. Every standing delegation states its reason. |
   | `## Monitoring` | How this environment waits on CI and conflicts, and what brings a paused session back. |
   | `## Environment-limited checks` | Which definition-of-done rows cannot run here and what the PR body or report must say about them. |
   | `## Submodules` | How each submodule edge is treated: tracked edges this ship bumps, pinned edges it never bumps, and what a dirty submodule checkout means. |
   | `## Report` | What the closing report must contain beyond the invariant lines in Step 6. |

4. **Say which file you read, by path**, in the plan and again in the report.
   A bundled default that was read silently is indistinguishable from a
   repository declaration, and the two carry different authority.

The policy file is **policy only**. It never restates the mechanics below, and
a policy file that contradicts an invariant does not win; report the conflict.

## Invariants — every environment, every route

**Signal hygiene.** This skill ends by saying "shipped", so a false success is
its worst failure. Read
[`signal-hygiene.md`](../../../docs/signal-hygiene.md) before changing
anything here. A push is verified by its own exit status and the remote's
response. A PR exists when its URL came back from the creation call. A merge
happened when the API returned a merge SHA. A remote holds a commit when, after
a fetch, `git merge-base --is-ancestor <sha> origin/<default>` exits 0. SHA
equality proves nothing: `HEAD == origin/main` is true when your commit landed
and when a rebase destroyed it.

**Authorization.** A commit, push, PR, or merge is an external action. The
invocation of this skill authorizes the route the policy file declares, within
the merge authorization it states, and nothing more. Passing checks are
evidence, not approval; review approval may satisfy a landing requirement
without authorizing the merge. Keep the three apart in the report
([`verification-terminology.md`](../../../docs/verification-terminology.md)).

**Required evidence.** Satisfy the repository's `docs/work/definition-of-done.md`
for the surface the change touches. Do not ship red and do not substitute a
weaker check for a documented one. Name every check skipped and why; afterwards
a silent skip and satisfied evidence look identical.

**Pointer discipline.** A submodule gitlink only ever records a commit
reachable from that submodule's default branch on its remote. Never a PR-branch
SHA, not even temporarily: a squash merge mints a new commit and deletes the
branch, and a fresh clone then cannot fetch the recorded object while every
existing checkout keeps working from local objects. Details and the
child-first merge cycle: [`references/submodules.md`](references/submodules.md).

**An owning repository's documented ordering overrides this skill's parent-PR timing.**
Read the owner's pointer workflow and the child's `docs/work/consumed-by.md`
during inventory. That ordering changes timing, never the required checks.

**The default branch is resolved, never assumed.**
`git symbolic-ref --short refs/remotes/origin/HEAD` names it; if unset,
`git remote set-head origin -a` first. A repository on `master` has no
`origin/main`, and a failed command that prints nothing looks like a clean
result.

**No history rewriting on shared refs.** Never `--force` a push. A
non-fast-forward rejection is a conflict to resolve on the branch, not a
capability problem.

**The working tree may be shared.** On a local machine several sessions often
work in one checkout, so `git status` shows the union of everyone's work. A
ship commits only the files **this session** changed, by its own record of
what it wrote; everything else is left exactly as found, never staged,
stashed, formatted, reverted, or pushed. The procedures that make that safe
(pathspec commits, a hook that would stash other sessions' edits, integrating
upstream through a temporary worktree, and pushing only this session's
commits) are in
[`references/shared-working-tree.md`](references/shared-working-tree.md),
and they load whenever the inventory finds a change this session did not make.

## Step 1 — Inventory

From the repository root:

1. `git status --porcelain=v1 -z`, then classify every dirty path against the
   session's own record of what it changed: **mine** ships; **foreign** (not in
   the record) is left as found and named in the report; **shared** (in the
   record, but its diff carries hunks this session did not write) stops the
   ship. Any foreign path means
   [`references/shared-working-tree.md`](references/shared-working-tree.md)
   applies from here on. Uncommitted work of the session's own that is not
   finished is a stop too: finish it or exclude it, and say which.
2. Commits on the current branch not on `origin/<default>` after a fetch:
   `git fetch origin && git log --oneline origin/<default>..HEAD`. Each is
   either one this session made or another session's unpushed work; a foreign
   commit is a stop before the push, since publishing it is that session's
   call.
3. **Each submodule** (parse `.gitmodules`; never hardcode the list): does its
   checkout carry commits not on its own default branch, or uncommitted
   changes? A dirty or advanced submodule checkout is handled as the policy
   file's `## Submodules` heading says; the usual answer for a pinned edge is
   to stop, because the work belongs in the submodule's own repository.

   **A failed fetch is not an empty result.** Behind the cloud proxy,
   `git -C <sm> fetch origin` fails for an unattached repository and the `log`
   that follows prints nothing, reading as "nothing to ship". Check the fetch's
   exit status; the no-remote fallback and its limits are in
   [`references/submodules.md`](references/submodules.md#inventory-without-a-remote).
4. **Declared parents.** If any repository that ships here carries
   `docs/work/consumed-by.md`, or a `.gitmodules` edge here carries
   `branch =`, load [`references/submodules.md`](references/submodules.md) and
   plan the pointer bumps it describes. A repository with neither has no
   parent work, and that is the common case.
5. **Print the ship plan**: environment and the signal that chose it; policy
   file read, by path; route and target branch; what ships; what will be
   skipped and why. A plan with nothing to ship ends here with that sentence.

## Step 2 — Capability

Prove the remote actions the route needs **before** the expensive checks.
Discovering at PR time that the session cannot open one costs a full suite run
and strands a pushed branch.

- **Push**, every route: `git push --dry-run origin HEAD:refs/heads/<branch>`.
  `--dry-run` writes nothing, so the branch need not exist. Behind the cloud
  proxy a 403 means the repository is not attached to the session; attach it
  (the `add_repo` tool of the claude-code-remote MCP server), checking the plan
  first so an already-attached repository does not spend a permission prompt on
  `already_present`. A 403 after attaching is a stop, not a retry.
- **Pull request**, pull-request route only. A green push probe says nothing
  about PR tooling: different credential, different service. With the GitHub
  MCP tools present, their presence is the probe. With the `gh` CLI,
  `gh repo view <owner>/<repo> --json viewerPermission -q .viewerPermission`
  must print `WRITE`, `MAINTAIN`, or `ADMIN`; one command covers both
  unauthenticated and unreachable. Do not add a token-scope test: fine-grained
  and App tokens carry no scopes and open PRs fine.

If the PR probe fails, stop and follow the repository's credential-recovery
runbook. Do not mint or rotate credentials from this skill; shared credentials
may belong to a wider fleet. If they say to push anyway, push, hand back
the compare URL, and report "branch pushed, PR not opened", never "shipped".

## Step 3 — Required checks

Run the rows of `docs/work/definition-of-done.md` whose surface the change
touches, minus what the policy file's `## Environment-limited checks` names as
unavailable here, which the PR body or report then states.

**Run a parent's checks against the gitlinks its candidate commit records.**
After pushing each child's branch, restore its clean checkout with
`git submodule update --checkout -- <child>` from the parent before checking
that parent. Do not overwrite uncommitted child work. A diagnostic run against
an unmerged child may explain a failure but cannot prove the candidate passes;
restore the recorded checkout afterwards. A failure against both versions is
the parent's own defect and must be fixed.

**A parent whose checks pass only against an unmerged child is a dependent parent: push its branch, but do not open its PR.**
Report that parent as deferred until the child merges. This applies recursively
to intermediate repositories as well as the top-level parent.

**Docs-only lane.** Run the repository's predicate from the Workshop mount.
Resolve `<mount>` from this skill's physical directory: follow the skill path
with `readlink -f`, then take the root above `.agents/skills/ship/`. Do not
resolve relative paths lexically from the consumer's symlink; see
[`skill-path-resolution.md`](../../../docs/skill-path-resolution.md).

```bash
bash <mount>/Tools/docs-only-diff.sh origin/<default>; echo "EXIT=$?"
```

Exit 0 selects the documented docs lane: skip only checks proven to read none
of the changed paths, and still run the whole-tree prose checks the repository
names. Exit 1 is not docs-only. Exit 2 is cannot-decide and is treated as 1.
The classifier selects applicability; it supplies no evidence and authorizes
nothing.

**Deferral to CI**, pull-request route only. A check may be deferred when all
four hold: the check provably reads nothing under the changed paths; CI runs
the identical check on this PR; the PR body names the check, that it was
deferred, and why; and the merge waits on the CI result regardless. Absent any
piece, run it locally.

**Kit drift**, when the repository adopts the fleet's cloud-session bootstrap
kit: `scripts/agent/session-start.sh` and `.claude/hooks/session-start.sh`
must be byte-identical to their templates under
`<mount>/docs/templates/cloud-sessions/` and executable. Test that the template
exists before comparing: `cmp` against a missing file fails exactly like a
drifted copy, and a missing template is "cannot evaluate", reported as such,
not drift. Real drift stops the ship; upstream the hotfix into the template
first, then redeploy.

## Step 4 — Land

Follow the policy file's `## Route`. Repository protection and its documented
landing route still bind: if a bundled local default selects direct push but
the repository requires PRs, stop before pushing and resolve the policy to a
pull-request route. Never bypass protection or silently reinterpret a rejection.

### Direct route

1. Commit the session's paths **by pathspec**, with a message that names the
   change, not the session:

   ```bash
   git add -N -- <new files>
   git commit -m "<message>" -- <every session path>
   git show --stat --format= HEAD        # exactly the session's paths, or stop
   ```

   A path that changed type (symlink to directory, or back) cannot go through
   a pathspec commit reliably; the shared-tree reference's temporary-index form commits
   it with the same scope. When another session's unstaged changes are
   present, inspect the hook behavior and use the repository-authorized safe
   equivalent if it would stash or rewrite them, as the shared-tree reference
   prescribes. Report the evidence and any bypass.
2. Confirm every commit in `origin/<default>..HEAD` is this session's,
   **before** integrating anything: a replay onto a moved default branch
   rewrites every commit in that range, foreign ones included. A foreign
   commit stops here, with the commits listed, until the user says whether
   they may be published with this ship.
3. Bring the branch current as `## Target branch` says. Fetch and inspect
   both the remote target and remote default. For a non-default target,
   integrate its remote tip as well as any base updates the policy requires;
   a rejection on that target cannot be resolved by checking only the default.
   If the required upstream is already an ancestor of `HEAD`, nothing to do.
   Rebase only unpublished session commits; merge upstream into an already
   published branch without rewriting it, unless the repository's policy
   requires another safe procedure. With foreign changes, use the shared-tree
   reference's temporary replay only for unpublished commits; otherwise stop
   and arrange isolated integration rather than mutate foreign paths. Re-run
   affected checks and update only clean submodule checkouts when gitlinks move.
4. Push: `git push origin <target>`. The push's own output and exit status are
   the verification. A non-fast-forward rejection means someone landed in the
   meantime: back to step 3.
5. Prove the child landing before recording any tracked parent pointer, then
   run the direct child-first cycle in
   [`references/submodules.md`](references/submodules.md#child-first-cycle-direct-route).
   Each parent resolves its own policy; a local child can have a PR-only parent.

### Pull-request route

1. Put the work on the branch `## Target branch` names, based on
   `origin/<default>`, and bring it current the way that heading says. First
   ask whether the remote already has the branch
   (`git ls-remote --heads origin <branch>`): a cloud harness pushes the
   session branch as it commits, and a rebase of a pushed branch cannot be
   pushed without `--force`. A pushed branch is brought current by merging
   `origin/<default>` into it; a squash merge later collapses the merge
   commit. Only a branch the remote has never seen is rebased. On 2026-10-20
   a session rebased first, found its push refused, and had to rebuild the
   merge on a second branch to land fast-forward.
2. Commit the session's finished paths before pushing, using the same scoped
   pathspec or temporary-index procedure and hook precautions as the direct
   route. Verify the commit contains exactly the intended paths; rerun checks
   if integration changed the candidate. Push with `-u`.
   For a dependent parent, stop here and report the deferred
   PR. Otherwise open the PR against the default branch. Title: the commit
   subject for one commit, the task name for several. Body: what changed,
   which checks ran here, which were deferred or unavailable and why. Record
   the returned URL; no URL, no PR.
3. Several repositories shipping together cross-link their PR bodies so the
   change set reads as one unit. Submodule PRs come first and the superproject
   PR carries **no** pointer bump until the child has merged
   ([`references/submodules.md`](references/submodules.md)).
4. Arm the return path `## Monitoring` names. In a cloud session that is the
   PR-activity subscription; its limits and the two-scheduler trap are in
   [`references/cloud-return.md`](references/cloud-return.md).
5. Watch CI the way `## Monitoring` says. Red checks and merge conflicts are
   fixed **on the same branch** and pushed; the PR updates in place. Never a
   second PR for the fix. A gitlink conflict resolves to the SHA that is later
   on the submodule's default branch, never the earlier one.
6. **Merge or stop**, exactly as `## Merge authorization` says. A standing
   delegation merges (squash, one commit per change) once its stated evidence
   is in hand. Anything else stops here with the PR open, and the report names
   who the merge waits on and what will bring the session back. `ship merge`
   re-enters at this step.

**A deferred parent opens here.** After its child merges, verify the returned
merge SHA on the child's remote default branch, record that SHA in the parent,
and rerun the parent's checks against the new recorded gitlink. Only then push,
open the parent PR, cross-link it, arm its return path, and wait on its checks.
A branch without a PR may have no CI, so waiting for CI before opening cannot
replace the local check. Apply the parent's own merge authorization; the child
approval does not authorize its parent. While that PR awaits authorization,
report its old and new pointers and URL, and leave higher parents deferred.
The full cycle is in [`references/submodules.md`](references/submodules.md).

## Step 5 — Prove the landing

Always, both routes:

```bash
git fetch origin
git merge-base --is-ancestor <landed-sha> origin/<default>   # exit 0 = the remote contains it
git rev-parse origin/<default>                                # context for the reader, not the assertion
```

For a direct policy targeting a non-default branch, test containment against
`origin/<target>` instead and report "pushed to <target>"; it has not landed
on the default branch.

The landed SHA is the pushed commit on a direct route and the merge SHA the API
returned on a pull-request route. The tip print is context: another change
landing between merge and proof moves the tip legitimately, and containment is
the question that survives that.

Pull-request route, afterwards:

- `git fetch --prune origin` in every repository that merged. A squash merge
  deletes the remote branch but the local tracking ref survives, and stale
  refs make range-based tooling report merged history as unpushed.
- **Reset the session branch only when loss-free.** The test is "the branch
  tip is exactly the commit the PR merged": `git rev-parse <branch>` equals the
  PR's head SHA (`gh pr view <n> --json headRefOid`, or the PR tool's
  `head.sha`). Foreign staged or unstaged changes stop branch cleanup even
  when the tips match: leave the checkout and report it. Otherwise equal → `git checkout -B <branch> origin/<default>` and
  `git submodule update`. Different → leave it and report
  `git log --oneline <merged-head>...<branch>` (three dots). Never substitute
  an ancestry or `git cherry` test: the squash minted a new commit, so both
  misreport a merged branch as unmerged. Without PR tooling, compare against
  `origin/<branch>` **before** pruning, since pruning destroys that evidence.
- Cancel any insurance timer the ship armed, in the same scheduler family that
  armed it ([`references/cloud-return.md`](references/cloud-return.md)).
- Any pointer bump owed to a declared parent runs now, child-first, per
  [`references/submodules.md`](references/submodules.md).

## Step 6 — Report

Every report carries these lines, then whatever the policy file's `## Report`
heading adds:

- environment, and the signal that chose it;
- policy file read, by path, and whether it was the repository's or a bundled
  default;
- what landed: branch, SHA, PR URL where one exists, and the containment line
  from Step 5 quoted (`merge-base --is-ancestor exit 0`);
- checks run, checks deferred, checks unavailable, each named;
- what is pending or was declined, by name: an open PR awaiting a human, a
  declared parent still recording the pre-merge pointer with both SHAs, a
  dirty submodule left alone;
- what was left for another session, by path: foreign dirty files, foreign
  staged files, foreign unpushed commits; and whether the commit hook was
  bypassed, with the step run that stood in for it;
- what, if anything, is armed to bring the session back.

Say "shipped" only about a landing Step 5 proved. A pushed branch without a
PR, an open PR, and a merged child with a lagging parent are each reported in
their own words.

## Failure modes

- **CI red on a PR** — fix on the same branch and push.
- **Branch behind its default** — fetch, then rebase an unpushed branch or
  merge `origin/<default>` into a pushed one, then `git submodule update`
  immediately; a rebase or merge that moves pointers leaves submodule working
  trees stale and can wedge the operation itself.
- **Gitlink conflict on rebase** — keep the SHA that is later on the
  submodule's default branch (`git -C <sm> merge-base --is-ancestor <A> <B>`;
  exit 0 means B is later). The earlier one moves the pointer backwards while
  a reachability check stays green.
- **Policy file and invariant disagree** — the invariant holds; report the
  conflict so the policy file gets fixed.
- **Session ends mid-route** — open PRs are durable server-side state; a later
  session runs `ship merge`. The session's own return is a separate question
  answered by `## Monitoring`, never assumed.

## Hard "do NOT" list

- **Do NOT merge beyond what `## Merge authorization` grants.** With no
  standing delegation, merging needs the maintainer's go-ahead in the current
  conversation.
- **Do NOT open a parent PR whose checks cannot pass against its recorded gitlinks.**
- **Do NOT record a pointer to a PR-branch SHA**, not even on a branch.
- **Do NOT force-push**, and do NOT resolve a non-fast-forward with `--force`.
- **Do NOT sweep another session's work into a commit, a stash, a format, or a
  push.** No `git add -A`, `git add .`, `git commit -a`, `git stash`,
  `rebase --autostash`, `reset --hard`, `checkout -- .`, `clean`, or branch
  switch in a tree that carries changes this session did not make.
- **Do NOT report "shipped"** without the containment line, or while a declared
  parent still records the pre-merge pointer without naming it.
- **Do NOT re-issue a scheduling or attachment call that was rejected**; each
  is a permission prompt on the maintainer's device.
- **Do NOT tag, release, publish, or deploy.** Out of scope.
