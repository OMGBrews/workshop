---
name: ship
description: Ship finished work from a PR-flow (cloud) session — open coordinated PRs for changed submodules and the superproject, then merge them child-first on the maintainer's go-ahead
compatibility: Written for Claude Code on the web, whose sandbox blocks direct pushes and makes a pull request the only way to land work. The coordinated submodule-then-superproject ordering generalises, but a session that can push directly should do that instead of following this skill.
---

# Ship

Turn finished work in a superproject workspace into merged default-branch state via pull requests. This is the PR-flow counterpart of the standard local flow ("commit inside the submodule, push, bump the pointer") for environments where direct pushes to the default branch are blocked — Claude Code on the web sessions behind a git proxy, or any repo with branch protection.

A bare `ship` invocation inventories the work, proves this session can push *and* open PRs, runs the required checks, pushes branches, opens PRs, and **stops for review**. The merge sequence (Phase 7) runs only on the maintainer's explicit go-ahead in the conversation — `ship merge`, or a plain "merge it" after they have reviewed the PRs.

**Arguments**: optional `[merge]`. Bare runs Phases 1–6 and stops for review; `merge` runs the Phase 7 merge sequence, and is accepted only after the maintainer has reviewed the PRs.

Shipping here means landing changes. It does not release, publish, promote,
deploy, or mint any public artifact. Those later lifecycle boundaries keep
their own requirements, authorization, runbooks, and sign-off.

**Environments.** In a Claude Code on the web cloud session, the PR operations named below are the GitHub MCP tools (`create_pull_request`, `update_pull_request`, `merge_pull_request`, `pull_request_read`) and repo scope comes from `add_repo`. On a local machine without that MCP server, substitute the `gh` CLI one-for-one (`gh pr create`, `gh pr view`, `gh pr merge --squash`) — the phases do not change. And where the workspace's documented convention is direct pushes to the default branch (typical local devcontainer work), `ship` is unnecessary ceremony: the standard commit → push → bump flow remains first-class (see [`shipping-conventions.md`](../../../docs/shipping-conventions.md)), and this skill earns its keep only where merges must travel through PRs. A workspace that holds many repositories at once may also have its own sweep that records pointers in batch; where one exists it is the cheaper route, and this skill is for the sessions that have no such workspace.

## Conventions used throughout

**Signal hygiene.** This skill moves work across repositories and ends by reporting "shipped," so a false success is the worst failure available to it. Read [`signal-hygiene.md`](../../../docs/signal-hygiene.md) before changing anything here. Concretely: a push is verified by its exit code and the remote's response, a PR exists when its URL came back from the creation call, a merge happened when the API returned the merge SHA. Never report a step you cannot evidence.

**Pointer discipline — the one hard rule.** A submodule gitlink recorded in the superproject must only ever reference a commit **reachable from that submodule's default branch on its remote**. Never record a PR-branch SHA: a squash (or rebase) merge mints a *new* commit for the default branch, the PR branch gets deleted, and the branch SHA becomes unreachable — a fresh clone of the superproject then cannot fetch the submodule commit at all. Existing checkouts keep working from local objects, which is exactly why the breakage hides. This is why the pointer bump is the **last** step, after the submodule PR has merged, using the SHA the merge API returned.

**Merge order: children before parents, applied recursively.** A superproject PR merges only after every submodule PR it depends on has merged and the pointer has been re-recorded to the post-merge SHA. In a nested tree (workspace → project → shared library), that means deepest-first: the deepest changed repo merges, its immediate parent records the pointer and merges next, and so on upward — every repo whose gitlinks moved gets its own PR.

**`$DEFAULT_BRANCH` — resolve it, never assume `main`.** A repo whose default branch is `master` or `develop` has no `origin/main` ref at all, so any command referencing it fails — and a failed command that prints nothing looks exactly like a clean result. Resolve it per repo:

```bash
git -C <repo> symbolic-ref --short refs/remotes/origin/HEAD    # -> origin/main, origin/master, ...
```

If `origin/HEAD` is unset, `git -C <repo> remote set-head origin -a` first.

**Two classes of submodule edge, and only one of them is this skill's to bump.** The discriminator is mechanical — the `branch` key in the parent's `.gitmodules`, never the directory name:

- **Composition** (`branch = main`) — a superproject and a real component of it: a game client inside its project repo, a CMS inside the same, a library inside the environment that develops it. A component can have **more than one** parent — a shared package mounted inside several clients is the case that proves it — so a component's parent list is a *list*, and reading only the first entry silently drops the rest. A stale pointer here presents an old component as the superproject's current one, which genuinely misleads (found-in-words cms, 2026-07-21 — 14 commits and 11 task documents invisible behind one). This skill bumps these **by default**, fetching the parent when this session does not already mount the child inside it: Phase 1 step 3 plans it, [Phase 7's unattached-parent cycle](#the-unattached-parent) runs it.
- **Distribution** (no `branch` key — pinned) — this repository itself is the common case, mounted at `workshop/` by every consumer that adopts the shared rules. This skill never bumps one, and the reason is not effort: **no session holds twenty parents, and none should.** A pinned pointer moves when its owner asks and at no other time, so a lagging pin is the expected state rather than a defect, and there is nothing here for a ship to offer. Say so and move on. A repository that nests this one as a tracked component — a maintainer wrapper whose `workshop/` edge carries `branch = main` — is composition, not distribution, and the discriminator gets that right without being told.

The `branch` key is a declaration about *who owes a bump*, not about what the submodule contains: a tracked edge names a pointer someone is expected to move promptly, a pinned edge names one that moves only on request. Propagating a pinned edge across many consumers is a separate, deliberate act with its own playbook, owned by whoever maintains that set of consumers — it is never something a ship improvises.

This skill ships from Workshop, so a consumer receives it the same way it receives the other shared skills: by moving its pinned `workshop/` pointer and re-running `Tools/sync-skill-symlinks.sh`. Nothing arrives on its own — a consumer sitting on an older pin does not have this file, and a session cannot tell from inside the skill which pin loaded it.

## Phase 1 — Inventory

Establish what needs shipping. From the superproject root:

1. For each submodule (parse `.gitmodules` — never hardcode the list — and recurse into each submodule's own `.gitmodules`): does its checkout carry commits not on `origin/$DEFAULT_BRANCH`? (`git -C <sm> fetch origin`, then `git -C <sm> log --oneline origin/<default>..HEAD`.) Uncommitted changes inside a submodule mean the work is not finished — stop and finish it first.

   **The fetch can fail, and a failed fetch is not an empty result.** In a cloud session the proxy serves only attached repos, so `git -C workshop fetch origin` dies with `could not read Password for 'http://local_proxy@...': terminal prompts disabled` (found-in-words-cms, 2026-07-29). Under `set -e` that aborts; unguarded in a loop it is worse — the `log` that follows prints nothing and the edge reads as "nothing to ship." Check the fetch's exit code and take the fallback explicitly:

   ```bash
   if git -C "$sm" fetch origin 2>/dev/null; then
     git -C "$sm" log --oneline "origin/$default..HEAD"          # authoritative
   else
     # No remote available. This question is still answerable without one:
     # a clean checkout sitting exactly on the gitlink the superproject records
     # cannot carry work this session created.
     recorded="$(git -C <super> rev-parse ":$sm" 2>/dev/null || git -C <super> ls-tree HEAD "$sm" | awk '{print $3}')"
     if [ -z "$(git -C "$sm" status --porcelain)" ] && [ "$(git -C "$sm" rev-parse HEAD)" = "$recorded" ]; then
       echo "$sm: no unshipped work (verified without a remote: clean, HEAD == recorded gitlink)"
     else
       echo "$sm: UNKNOWN — fetch failed and the checkout has moved or is dirty" >&2
     fi
   fi
   ```

   Say which branch ran, in the plan and in the Phase 6 report. The fallback is conclusive for *this* question and must be labelled for what it does not answer: it says this session introduced nothing, not that the recorded pointer is current. The `UNKNOWN` branch is a stop, not a shrug — an edge that has moved with no remote to compare against is exactly the case where guessing ships or drops real work.

   **Do not "fix" this by skipping pinned edges.** It is tempting — the skill never bumps a pinned pointer, so why fetch one — but the inventory question is not "will this pointer move," it is "does this checkout carry commits nobody has pushed." Editing a mounted shared tree from inside a consuming project is a *normal* way changes to it are made, and a pin suppresses pointer movement only; such a checkout still carries real unshipped work. Skip it and the inventory goes quiet on the one edge most likely to be dirty.

2. Superproject: `git status --short` for uncommitted work, plus commits on the session branch not on `origin/<default>`.
3. **Declared parents.** For each repo that ships, read its own declaration — `docs/work/consumed-by.md`. The declaration is the source and inference is not a substitute: a child cannot discover its parents from its own git metadata — a submodule edge is recorded only in the parent — and in a cloud session the parent is usually not on disk at all. Extract the block, then validate every line in it — both halves, always:

   ```bash
   f="<repo>/docs/work/consumed-by.md"
   if [ ! -f "$f" ]; then echo "no declared parents"; else
     decl="$(awk '/^<!-- CONSUMED-BY:END/{exit} p && NF; /^<!-- CONSUMED-BY:BEGIN/{p=1}' "$f")"
     bad="$(printf '%s\n' "$decl" | grep -Evx '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' || true)"
   fi
   ```

   Every character of that awk is load-bearing. The sentinel patterns are **anchored to the start of a line**, so a sentence that names a sentinel cannot open the block: unanchored, the same extraction *returned* 15 lines of prose and `## See also` links from a shared-tooling repo's own `consumed-by.md` while that file still quoted both sentinels in one sentence (measured 2026-07-28), and an `owner/repo` string inside a sentence becomes a phantom parent that this skill then attaches, clones, bumps and opens a PR against. Both sides were fixed — the file was reworded *and* the extraction anchored — because either alone leaves the next author one sentence away from the same failure. The `exit` on END stops at the **first** closing sentinel, so a second sentinel pair later in the file cannot re-open the block; the first pair in the file is the declaration, which is why no declaration file may carry a second literal `<!-- CONSUMED-BY:` at the start of a line (a file that demonstrates the format in an example block above its real one would have the example parsed). And a non-empty `$bad` is a **malformed declaration** — a line that is not an `owner/repo` pair — which stops the plan and gets reported; never drop it silently, and never let it through as a parent.

   Three outcomes, and the middle two are not the same thing:

   - **No file** → no declared parents, nothing to offer. Not an error, not a warning — unadopted repos degrade gracefully by design.
   - **File present, `$decl` empty** → a **broken declaration**: a mangled sentinel, an emptied block. Report it as broken and plan no parents for that repo. It is *not* "no declared parents" — the missing-file branch prints its own message while this one prints nothing at all, so an agent skimming output collapses the two and ships a silent lag.
   - **`owner/repo` lines** → one **default** "parent pointer-bump" entry in the ship plan per line, unless this session already **mounts** the child inside that parent (below). `owner/repo` is the only item form the grammar admits: every line names a real repository, and there is no reserved word for "many consumers, none of them owed a bump" — a pinned consumer belongs on no list at all (see the two classes of edge above).

   **Docs-only ships flip the parent default.** When everything a repo ships this run is docs-only per its documented predicate (Phase 3's fast-lane conditions), plan a **declared lag notice** for each `owner/repo` parent instead of a pointer-bump PR: docs churn — task moves, journal entries — would otherwise mint a clone + PR + merge per edit, and where the maintainer has a workspace-wide sweep, that is the convergence path for `branch = main` edges and records these in batch anyway. The notice still names the parent and both SHAs in the report, and the maintainer asking for the bump restores the full cycle.

   **The discriminator is the mount, not the attachment.** Phases 4-7 record a pointer with `git add <sm>` in a checkout that has the child **inside** it as an initialized submodule; that, and only that, is what "already covered" means. Attachment does not imply it — the ordinary cloud-session guidance is to attach the two or three repos a change needs with the multi-repo picker, which puts parent and child **side by side**, not nested. So a parent that is attached but does not mount the child here is covered by nothing and must still get a plan entry:

   - **Mounts the child here** → no entry; the existing phases bump it.
   - **Attached, does not mount it** → an entry, run by [the unattached-parent cycle](#the-unattached-parent) minus its first two steps: proxy scope already exists and the checkout is already on disk.
   - **Neither** → an entry, the full cycle.

   To recognize a declared parent among this session's repos, run **both sides** of the comparison through this repository's `Tools/normalize-remote.sh`, resolved from this skill's physical location ([`skill-path-resolution.md`](../../../docs/skill-path-resolution.md)) — `WORKSHOP_ROOT="$(dirname "$(readlink -f .claude/skills/ship/SKILL.md)")/../../.."` lands on this tree's root in the upstream layout, under any mount name, and from a vendored copy — and compare the results:

   ```bash
   mine="$(git -C <repo> remote get-url origin | "$WORKSHOP_ROOT/Tools/normalize-remote.sh")"   # -> omgbrews/plunk
   theirs="$(printf '%s\n' "$decl" | "$WORKSHOP_ROOT/Tools/normalize-remote.sh")"               # the declaration lines
   ```

   **Both sides, always** — that is the whole point, and normalizing only the remote is the failure this replaced. The script lowercases, because casing is not identity here and a session does not control it: `add_repo` reported `omgbrews/found-in-words` against a declaration written `OMGBrews/found-in-words`, which is on its own enough to make every match fail. Normalizing on read is deliberately chosen over requiring lowercase declarations, so the ten existing declaration files stay as their authors wrote them.

   It matches the **trailing `owner/repo` pair** rather than stripping known prefixes, and that is not a refactor. A prefix-stripper has to be taught every URL shape in advance, so it fails on the first one nobody enumerated — which is precisely this defect's class. It shipped missing the `ssh://` arm; then a cloud session's proxy origin, `http://local_proxy@127.0.0.1:<port>/git/<owner>/<repo>`, walked through the `https?://[^/]+/` arm and came out as **`git/OMGBrews/found-in-words-cms`**, the proxy's `/git/` segment intact, matching nothing (found-in-words-cms, 2026-07-29).

   And it **exits non-zero on input it cannot reduce to a pair** rather than echoing it back. A normalizer that passes garbage through does not announce a problem — it hands the caller an unmatchable string, and the caller reports the parent as absent. Read its exit code; do not compare its output blind.

   Because that misclassification is silent, its cost is not a warning but duplicated work: every declared parent lands in the "neither" branch below, so a parent that **does** mount the child in this session gets its pointer recorded by Phases 4-7 *and* a second clone and a competing PR from the unattached-parent cycle — two PRs moving the same gitlink for one change. Regression test: this repository's `tests/test-normalize-remote.sh`, which asserts each remote URL shape including the cloud proxy's.

   **The plan closes transitively.** A parent that receives a pointer-bump PR is itself a repo that ships, so read *its* declaration (`docs/work/consumed-by.md`) the same way and add its declared parents, repeating until nothing new appears. The depth is whatever the declarations say, and the shape that makes it bite is a shared package mounted in several clients: shipping the package plans a bump in **every** client that declares it, and each of those clients declares its own superproject, whose pointer goes stale the moment the client's bump merges. Stop at one level and those superprojects have nothing planned and nothing said — the same silent lag, one level up. Follow the declarations rather than a remembered depth; a hard-coded number is wrong the first time someone adds a level.

4. Print the ship plan: per repo, what ships and on which branch, plus every parent pointer-bump entry and lag notice from step 3, each named explicitly. If only the superproject changed, say so — the plan degenerates to a single PR, and that is fine. The maintainer declines a parent bump by striking its entry; offering it here, before the checks, is what makes the default cheap to refuse.

## Phase 2 — Ship capability

This skill's two remote actions — **pushing a branch** and **opening a PR** — run on independent credentials, and either can be missing while the other works. Probe both here, against every repo in the Phase 1 plan, before the verification suite: the checks are this skill's expensive phase, and discovering at PR time that the session cannot open one costs a full suite run and strands a pushed branch with no PR on it (found-in-words-cms kaizen, 2026-07-22).

**Push.** In a cloud session the git proxy only serves repos attached to the session; a push to an unattached repo fails with HTTP 403.

```bash
git -C <repo> push --dry-run origin HEAD:refs/heads/<branch>
```

`--dry-run` writes nothing, so the branch need not exist yet. On 403, add the repo to the session (`add_repo` on the claude-code-remote MCP server, owner/repo taken from the submodule URL), then probe again. **Check what this session has already attached before issuing one**: `add_repo` is a permission prompt like any other, and for a repo attached earlier it spends that prompt to return `already_present` — a no-op the maintainer had to approve. A context summary that dropped the first call's result is the usual cause of the blind re-issue (found-in-words-cms, 2026-07-30), so keep the attachment list in the ship plan where a summary preserves it, and read it rather than re-probing. A 403 *after* adding is a different problem — stop and report it rather than retrying. A rejection that is **not** a permission error — typically `! [rejected] … (non-fast-forward)` against a branch this session already pushed — is not a capability failure and does not belong here: leave it to Phase 4, and never resolve it with `--force`.

**Pull request.** A green push probe is **no** evidence that a PR can be opened — different credential, different service — and `add_repo` grants proxy scope, not PR tooling. Probe whichever path this session is on:

- *GitHub MCP*: presence is the probe — `create_pull_request` is in this session's tool list. Nothing to run.
- *`gh` CLI* (any session without those tools): for each repo in the plan, `gh repo view <owner>/<repo> --json viewerPermission -q .viewerPermission` must print `WRITE`, `MAINTAIN`, or `ADMIN`. One command covers both failure modes — it exits non-zero when `gh` is unauthenticated *and* when the account cannot reach the repo. Do **not** additionally condition this on OAuth token scopes: fine-grained PATs, `GH_TOKEN`, and GitHub App tokens carry no scopes at all yet open PRs fine, and `public_repo` suffices for a public repo without containing the literal string `repo` — a scope check false-reds capable sessions.

**If the PR probe fails, stop here — before the checks — and put it to the maintainer.** The fix is theirs to run: `gh auth login` is interactive and cannot be completed from a tool call, so ask for it as a command in their own shell (`! gh auth login`), then re-probe and continue. Stopping now costs no throughput — the session blocks on the human either way — and leaves nothing half-shipped while it waits. If the maintainer instead says to just push, that is an ordinary instruction: push, hand back each repo's compare URL, and report "branch pushed, PR not opened" — never "shipped".

**What this phase deliberately does not cover: the unmounted parents.** `git push --dry-run` needs a clone, and a parent nobody has cloned yet has none — so this preflight cannot evaluate the repo whose access is least certain. Its capability is checked where first needed, by `add_repo` in [the unattached-parent cycle](#the-unattached-parent), and a failure there is **reported** as a parent left pending, never retried into the merge sequence. `git ls-remote https://github.com/<owner>/<parent>.git` needs no clone and may be run here as an early look, but it is neither required evidence nor a gate: behind a git proxy it is subject to the same scope as a push, so a failure says `add_repo` is still owed, not that the ship is blocked.

## Phase 3 — Required checks

Run each changed repository's documented checks and satisfy its definition of
done. Do not ship red, and do not substitute a weaker check for a documented
one. If the workspace documents environment-limited checks, state in the PR
body which checks ran here and which are unavailable or deferred; never make a
silent skip look like a pass.

**Diff-scoped deferral (docs-only diffs).** When *every* changed path in a repository lies provably outside a check's read set — the canonical case is a docs-only diff against checks that lint, type-check, and test only code — the local check may be deferred to CI, which runs the same check on the PR. All four conditions must hold, or run the check locally as usual:

1. **Proven, not assumed**: verify the check reads nothing under the changed paths (inspect what the lint/test targets actually cover — a repository where tests read Markdown does not qualify). "It's just docs" is a claim; the check's target list is the evidence.
2. **The check still runs machine-side, exactly once, before or immediately after merge.** The usual form is CI running the identical documented check on this PR: deferral moves the run, it never removes it. If CI itself skips the check for this diff, both ends may skip only through a **documented fast lane** with one shared classifier, evidence that the check reads nothing the classifier admits, CI reporting the check as skipped rather than passed, and the full check running on every push to the default branch. Absent any piece, run the check locally.
3. **Declared in the PR body**: name the check, that it was deferred to CI, and why the diff cannot affect it.
4. **The merge still waits on the CI result** (Phase 7 step 1 checks it regardless) — deferring the local run never means merging past a pending or red check.

This trades nothing away — the check still runs machine-side exactly once before merge — and removes the double payment of running an identical multi-minute check twice on a diff that cannot change its outcome (found-in-words-cms kaizen, 2026-07-20).

**Kit drift check.** If the superproject adopts the cloud-session bootstrap kit, **both** deployed copies must be byte-identical to their canonical templates and executable — the harness-neutral bootstrap and the Claude Code wrapper that calls it. The wrapper deploys to `.claude/hooks/` — Claude Code's own hooks directory, the subject matter of this check. This skill and the templates ship in the same repository, so whatever mount loaded this file also carries them — resolve both from this skill's physical location rather than by mount name ([`skill-path-resolution.md`](../../../docs/skill-path-resolution.md)):

```bash
kit="$WORKSHOP_ROOT/docs/templates/cloud-sessions"
for pair in "agent-session-start.sh:scripts/agent/session-start.sh" \
            "session-start.sh:.claude/hooks/session-start.sh"; do
  tpl="$kit/${pair%%:*}"; dep="${pair#*:}"
  [ -f "$dep" ] || continue                      # not adopted: not a failure
  cmp "$tpl" "$dep" && [ -x "$dep" ] || echo "KIT DRIFT: $dep"
done
```

A repo carrying the wrapper but **not** `scripts/agent/session-start.sh` is a half-adopted kit, not an opt-out: the hook fires and nothing bootstraps. Deploy the neutral half before shipping.

On failure, stop and reconcile before opening any PR — shipping a drifted copy propagates the drift. The template is canonical: upstream any hotfix from the deployed copy into the template first, then redeploy template → copy (`cp` + `chmod +x`). Rationale and the per-session seam of the same guard: [the kit README](../../../docs/templates/cloud-sessions/README.md).

## Phase 4 — Submodule branches and PRs

For each submodule with work to ship:

1. Put the work on a branch based on `origin/$DEFAULT_BRANCH`: `git -C <sm> switch -c claude/<task-slug>` (commits made on a detached HEAD or a local default-branch checkout come along).
2. Push: `git -C <sm> push -u origin claude/<task-slug>`.
3. Open the PR via the GitHub MCP `create_pull_request` (base = the default branch). Title: the commit subject (single commit) or the task name (several). Body: what changed, which checks ran, and a placeholder line for the superproject PR link. Record the returned URL — no URL, no PR.
4. **Restore the submodule checkout to the recorded pointer**: from the superproject, `git submodule update --checkout <sm>`. The pushed branch and its PR are untouched (only the working checkout detaches), and the superproject tree goes clean instead of showing `M <sm>` gitlink drift for the whole review pause — drift that `git status` readers and stop hooks rightly flag, and that must **not** be silenced by committing the pointer (that would record a PR-branch SHA). Phase 7 checks out the merge SHA anyway (llmkit-dev, 2026-07-19).

In a nested tree, treat an intermediate repo (one that is both child and parent) the same way: its PR ships its own changes but **no** pointer bumps for children whose PRs have not merged — those land during the merge sequence, level by level.

## Phase 5 — Superproject branch and PR

1. Commit the superproject work — docs, config — **without bumping pointers whose submodule PR has not merged yet** (pointer discipline). It is normal for this PR to be temporarily incomplete (e.g. a skill symlink that only resolves after the pointer bump); say so in its body.
2. Push the session's branch (in cloud sessions, the designated `claude/...` branch) and open the PR the same way.
3. Cross-link: edit each PR body (`update_pull_request`) so every PR in the change set links the others — one change, N repos, one navigable unit.
4. **Subscribe to every PR opened** (`mcp__github__subscribe_pr_activity`) — this is the session's primary way back, not a nicety. A **merge** is delivered: measured at ~8 seconds, with an automatic unsubscribe once it lands (measured 2026-07-29 — [`session-return-durability.md`](../../../docs/session-return-durability.md)). Review comments arrive the same way.

   Do **not** extend that result to CI. The subscription's own confirmation message states that webhooks "don't reliably deliver CI success, new pushes, or merge-conflict transitions" — so a subscription is evidence a merge will reach you, and no evidence at all that a green build will. Phase 7 step 1 still reads the checks itself rather than waiting to be told about them.

5. **Arm an insurance timer only when step 4 did not arm.** The default is subscription-only: do **not** schedule a check-in behind a live subscription. In a cloud session every `mcp__Claude_Code_Remote__send_later` call is a permission prompt on the maintainer's phone, and a duplicate return path is the weakest thing a prompt can buy — one ship spent seven scheduling and attachment calls, not one of them about the diff, and still left a Routine armed past the merge it was insuring ([`session-return-durability.md` → the cost side](../../../docs/session-return-durability.md#the-cost-side--what-arming-the-timer-charges-measured-2026-07-30)).

   The condition for arming is **"the subscription is not the return path"**, and nothing softer: `subscribe_pr_activity` errored, is absent from this session's tool list, or came back without confirming a subscription. Then the timer is the *only* way back and is worth its prompt. Do not try to infer whether a human is watching — the tool answers that question for you, below.

   **One check-in per ship, not per PR.** A ship is one unit of work with one return; per-PR timers spend their next prompts reconciling each other, which is how the 2026-07-30 run produced a rejected duplicate and two cancellations.

   **A rejected or errored scheduling call ends the attempt.** `MCP error -32003: MCP tool call requires approval` and an outright denial are both answers, not transient faults. Do not re-issue the call with equivalent arguments — proceed on whatever return path remains and say in Phase 6 that nothing is armed.

   **Arm and cancel in the same family** (`send_later` ↔ `list_triggers`/`delete_trigger`, never `CronDelete`), and cancel when the work it insured is over — Phase 7 step 6. The two stores cannot see each other and a cross-family miss reads exactly like data loss; the trap, and its byte-for-byte reproduction, are in [`session-return-durability.md`](../../../docs/session-return-durability.md).

## Phase 6 — Stop for review

Report, per repo: the PR URLs opened; the pointer bumps still pending a child's merge, **including every parent bump planned in Phase 1**; and every parent the maintainer has already declined, named. A decline belongs in the report, not only in the conversation — the report is what the next session and the PR bodies inherit, and an unrecorded decline is indistinguishable from an oversight.

**Close the report by naming who the merge is waiting on, and what will bring this session back — always, in one line.** The PRs are open, merging is the maintainer's call, and a PR-activity subscription (Phase 5 step 4) should carry the merge back here within seconds. Name what is actually armed — subscription, scheduled check-in, both, neither — rather than implying a return you have not set up. If nothing is armed, say that plainly: the maintainer should never have to work out from silence whether the ball is in their court.

**"Subscription armed, no timer" is the expected line, not a gap** — Phase 5 step 5 makes the timer conditional, so its absence is the design working and should be reported in those terms rather than as a shortfall. The line to avoid is silence about either path; naming a path costs nothing, and arming one you did not need costs the maintainer a prompt.

**Stop.** Do not merge and do not enable auto-merge. Merging is the maintainer's call, given in the conversation — the same boundary a release sign-off draws, one level down.

Passing checks provide evidence; they do not approve or authorize the merge.
Review approval may satisfy a landing requirement, while the maintainer's
explicit go-ahead in the current conversation supplies this skill's merge
authorization. Keep all three claims separate in the report.

**The one standing delegation: docs-only PRs (maintainer decision, 2026-07-29).** In a repo that documents the docs-only fast lane (Phase 3's conditions, all pieces), a PR whose diff is docs-only per that repo's predicate script does not stop here: merge it (squash) as soon as its classification check is green, and fold it into the same report — what merged, and the lag notice its parents inherit (Phase 1's docs-only default). The delegation covers exactly that class: a diff with any non-docs path, or a repo without the documented lane, stops for review as above.

## Phase 7 — Merge sequence (go-ahead only)

Run the cycle below bottom-up. In a nested tree an intermediate repo takes both roles: its PR receives the pointer bumps for its already-merged children (step 3) before it merges in its own turn (step 5), and the cycle repeats one level up until the outermost superproject has merged.

1. **Child first.** Confirm the submodule PR's required checks are green (`pull_request_read`) and that the maintainer has authorized the merge in the current conversation. Merge with `merge_pull_request`, `merge_method: "squash"` (one commit per change on the default branch). Capture the merge SHA from the response.
2. **Verify before recording**: `git -C <sm> fetch origin`, then `git -C <sm> merge-base --is-ancestor <merge-sha> origin/<default>` — exit 0 or stop.
3. **Record the pointer**: `git -C <sm> checkout <merge-sha>`, then in the superproject `git add <sm>` and commit, message per the workspace convention (`Bump <name> pointer: <what the child PR did>`). If the workspace has a post-bump step for this submodule (e.g. `workshop/Tools/sync-skill-symlinks.sh` after a Workshop pointer bump), run it and include the result in the same commit.
4. Push, and wait for the superproject PR's checks (if any) to go green.
5. **Parent last.** Merge the superproject PR (squash).
6. **Prove the end state** — two assertions, and the second is what carries the proof when the first has nothing to read:

   - **Per shipped submodule**: on the superproject's `origin/<default>`, the recorded gitlink is reachable from that submodule's `origin/<default>`. Print both SHAs, and print **how many gitlinks you inspected**.
   - **The merge itself, always**: after a fetch, the superproject's `origin/<default>` contains the merge SHA the API returned in step 5.

   ```bash
   git -C <repo> fetch origin
   git -C <repo> merge-base --is-ancestor <merge-sha> "origin/$default"  # exit 0 = the remote contains the merge
   git -C <repo> rev-parse "origin/$default"                             # evidence for the reader, not the assertion
   echo "gitlinks inspected: $(git -C <repo> ls-tree "origin/$default" | grep -c '^160000' || true)"
   ```

   The tip print is context, not a test: another PR merging between step 5 and here moves the tip legitimately, and containment is the question that survives that (`signal-hygiene.md`, "never verify a push by comparing SHAs").

   **The per-submodule assertion is empty in two ordinary shapes, so it cannot be the whole proof.** A repo that records no gitlinks at all — including one that tracks an empty `.gitmodules`, where `git ls-tree origin/main | grep '^160000'` prints nothing and exits 1 (verified 2026-07-30) — has an empty set, and so does *any* ship in which no submodule shipped. Quantified over nothing the condition holds having read nothing, with no SHAs to print: a ship that did nothing whatsoever passes it identically. That is the decorative check [`signal-hygiene.md`](../../../docs/signal-hygiene.md) says to delete rather than trust, and its prescribed remedy is the merge-containment assertion above — a positive property of the artifact this ship was supposed to produce. A live ship improvised exactly that substitution on 2026-07-29 and flagged it as its own judgment; it is prescribed here so the next one does not have to notice.

   **Report the count, and never let `0` print as a bare pass.** Say what happened, in these terms: `gitlinks inspected: 0 — no submodule pointers recorded, nothing to verify. Merge <sha> contained in origin/main (merge-base --is-ancestor exit 0).` An unqualified "end state proved" over an empty set is the same sentence a real N-gitlink pass writes, and a reader cannot tell the two apart — which is how a vacuous pass ends an investigation.

   **Cancel any check-in armed in Phase 5 step 5, here, without being asked.** A timer outlives the work it insured the moment every PR it covered reaches a terminal state — merged *or* closed unmerged — and one that fires into a finished session is pure noise. `delete_trigger` on the `trig_…` ID (never `CronDelete`: wrong store, and its "not found" is indistinguishable from real loss). Two things not to do: do not re-issue a `delete_trigger` the maintainer declined — record the live trigger's ID in the report so it can be cancelled deliberately — and do not go looking for a timer to cancel when the conditional rule armed none, which is the common case. If the ship is abandoned rather than merged, this cancellation is still owed.

   Then delete the merged branches unless the repo auto-deletes them, and `git fetch --prune origin` in every repo that merged — a squash merge deletes the remote PR branch but the *local* remote-tracking ref survives, and stale tracking refs make range-based tooling (e.g. a stop hook comparing `origin/<branch>..HEAD`) misclassify already-merged history as unpushed or unverified work.
7. **Leave the session branch on the merged history.** The squash merge minted a new commit, so the local session branch still holds the pre-squash originals — content that is now on the default branch, history that is not. Left in place, every `<upstream>..HEAD` range (stop hooks, the next session's tooling) reads them as unpushed or unverified work forever, and pruning cannot remove them (llmkit-dev, 2026-07-19 — the second stop-hook false-positive mode; prune fixed only the first). Reset **only when loss-free** — and be precise about what that means. It is *not* "the branch and the default branch are identical": those diverge the moment any **other** PR merges, which is the normal state of an active repo (found-in-words-cms, 2026-07-22 — the identity-with-default test reported 117 files and ~87k deletions of phantom "unshipped work" on a branch whose PR had merged). It is "this branch contributes nothing that is not already merged." Steps 1-2 already established the merge; do not re-derive it locally. What remains to show is that **the branch tip is exactly the commit the PR merged** — either test below does it, and both compare the *branch ref*, never `HEAD` (step 3 leaves a submodule detached):

     - `git rev-parse <session-branch>` equals the merged PR's head SHA (`pull_request_read` → `head.sha`; locally `gh pr view <n> --json headRefOid`). A string comparison, so a deleted remote head branch does not break it.
     - No PR tooling or no PR number to hand: `git rev-parse <session-branch>` equals `git rev-parse origin/<session-branch>`. The tracking ref records exactly what was pushed and survives the remote branch's deletion — **so run this before step 6's `git fetch --prune origin`, or move that prune to the end of this step.** Pruning first destroys the only evidence an environment without a PR API has.

     Equal → `git fetch origin`, then `git checkout -B <session-branch> origin/<default>`, and from the superproject `git submodule update`. Differ → leave the branch alone and report `git log --oneline <merged-head-sha>...<session-branch>` (three dots: after a local amend or rollback the branch may be *behind* the merged head, not only ahead, and a two-dot range prints nothing). If the branch ref no longer exists, there is nothing to reset and nothing to prove — say so rather than recreating it.

     Do **not** substitute a commit-identity or ancestry test. The squash minted a new commit, so `git log <default>..<branch>` and `merge-base --is-ancestor` both report the merged branch as unmerged. `git cherry` is worse than either: it is *conditionally* right — it detects a squash-merged **single-commit** branch (patch-identical) but not a multi-commit one, so it silently depends on how many commits the PR happened to have. (This is the same "restart the designated branch from the merged default" rule the cloud-session instructions give for follow-up work; running it here just does it at the moment the merge completes.)

If the session ends between Phases 6 and 7, nothing is lost: the PRs persist, and a later session runs Phase 7 from this file. That claim covers the **PRs**, which are durable server-side state. It does not cover the **session's own return**, and the two must not be conflated.

**A merge does wake the session, and the mechanism is a subscription, not a timer.** Both halves of that were measured 2026-07-29 — the webhook's latency, and the margin by which it beat a timer armed for the same purpose ([`session-return-durability.md`](../../../docs/session-return-durability.md); the numbers live there and are not restated here). The subscription is the plan, armed unconditionally in Phase 5 step 4.

**The timer is not the plan's backstop, because it is available only where it is redundant.** `send_later` can come back `MCP error -32003: MCP tool call requires approval`, and that is not an intermittent fault — it is what the tool does when the session lacks standing approval, so the call completes only if a human acts on it. Which splits cleanly: a session with someone reachable *can* arm the timer and least needs it, since that person is the return path; a session with nobody reachable *needs* it and cannot arm it at all. Arming reflexively therefore buys close to nothing and charges a prompt each way — one to arm, another to cancel when the merge lands first. Hence the conditional rule in Phase 5 step 5, and its evidence in [the cost side](../../../docs/session-return-durability.md#the-cost-side--what-arming-the-timer-charges-measured-2026-07-30).

Whatever the outcome, say it in the Phase 6 report in as many words: which paths are armed, and — if the subscription is the only one and it drops — that this session will not wake itself. Do not fall back to `CronCreate` as if it were equivalent; it dies with the session.

**The trap is not durability — it is that there are two schedulers and they cannot see each other.** Both exist in a cloud session:

| Family | Arm | List | Cancel | Scope |
|---|---|---|---|---|
| Server-side Routines | `mcp__Claude_Code_Remote__send_later` (also `create_trigger`) | `list_triggers` | `delete_trigger` | outlives the turn |
| Session-only cron | `CronCreate` | `CronList` | `CronDelete` | this session |

**Arm and cancel in the same family — always.** Hand a `trig_…` ID to `CronDelete` and you get `No scheduled job with id 'trig_…'` followed by `No scheduled jobs.` from a perfectly healthy job, because `CronList` enumerates only its own store. That is exactly what happened in the ship of 2026-07-29 that this note used to describe as a job "silently disappearing": it did not disappear. Its Routine records `ended_reason: "run_once_fired"` — it fired, and the cleanup was simply aimed at the wrong store. Reproduced deliberately, byte for byte, in the experiment above. **A "not found" from the wrong family is indistinguishable from real loss**, so read it as a question about which store you queried before you read it as a failure.

Prefer `send_later` for anything meant to outlive the turn; `CronCreate` is session-scoped. Neither is a substitute for the report: a Routine whose session is gone is auto-disabled (`ended_reason: "auto_disabled_session_gone"` was observed on a different Routine in the same account), so Phase 7 must still never be reachable **only** through a wake-up.

Two things this experiment did **not** settle, so do not claim them: whether a check-in scheduled *hours* out fires (the merge arrived first and the job was cancelled before its fire time), and whether a long-idle session is still reachable when its Routine fires.

### The unattached parent

For each parent pointer-bump entry in the Phase 1 plan — every declared parent this session does not already mount the child inside. It runs **after** the child's PR has merged — pointer discipline does not bend for it, so never a PR-branch SHA — and it is the cycle above with the parent's arrival in front of it: `add_repo`, a clone, and a path lookup a mounting parent never needs. A parent that is **attached but does not mount the child** skips steps 1 and 2 — proxy scope exists and the checkout is on disk; branch that checkout in place and start at step 3, binding `parent` to its path.

1. **`add_repo <owner>/<repo>`** (the claude-code-remote MCP server) — proxy scope for the parent, the same remedy Phase 2 uses for a 403, and the point at which this session's access to the parent is first actually tested (Phase 2 could not: no clone, no push probe). There is no `gh` equivalent and none is needed: locally the parent is either already on disk or one clone away, and a workspace that holds it has its own writer for that pointer, so this subsection is a cloud-session path.
2. **Clone it outside the child's working tree**, and branch immediately. A clone nested inside the child shows up as untracked files in the child's own diff and can be swept into a commit. Bind the clone directory once — the steps below all use `"$parent"`, never a bare repo name:

   ```bash
   parent="${TMPDIR:-/tmp}/<parent-repo>"
   git clone https://github.com/<owner>/<parent-repo>.git "$parent"
   git -C "$parent" switch -c claude/bump-<child>-pointer
   ```

3. **Find the submodule path by matching the child's clone URL** in the parent's `.gitmodules` — never by guessing the directory name. The guess has no basis at all here: at **none** of the ten composition edges does the mount path equal the child's repo name. `OMGBrews/plunk-game-client` sits at `game-client`, `OMGBrews/llmkit` at `library`, `OMGBrews/shared` at `<Game>/Packages/omgbrews-common-code`.

   ```bash
   # sm_path, never `path`: in zsh, lowercase `path` is the array tied to PATH, so
   # assigning it replaces PATH wholesale and every later command fails with
   # "command not found" (hit live 2026-07-28, and again 2026-07-29). The same
   # trap guards `cdpath`, `fpath`, `manpath`, and `prompt` — none may name a
   # variable in these snippets.
   sm_path="$(git config -f "$parent/.gitmodules" --get-regexp '^submodule\..*\.url$' \
     | grep -iE "[:/]<owner>/<child>(\.git)?$" \
     | sed -E 's/^submodule\.(.*)\.url .*/\1/' \
     | while read -r n; do git config -f "$parent/.gitmodules" "submodule.$n.path"; done)"
   ```

   **Test `$sm_path`, never `$?`.** A no-match leaves the pipeline's status at the `while` loop's, and that is **0** when the body never runs — non-zero only under `set -o pipefail`. Reading `$?` here therefore reports success in exactly the case the lookup exists to detect. Empty `$sm_path` means the declaration and the parent disagree: stop and report it, never guess a path. More than one line means the parent mounts the child twice: stop as well, and put the choice to the maintainer.

4. **Containment check before recording**, exactly as step 2 of the cycle above — run it in the child repo this session already has, which is the checkout that can certainly fetch the child: `git -C <child> fetch origin`, then `git -C <child> merge-base --is-ancestor <merge-sha> origin/<default>`, exit 0 or stop. Then record the pointer in the parent: `git -C "$parent" submodule update --init -- "$sm_path"`, `git -C "$parent/$sm_path" fetch origin`, `git -C "$parent/$sm_path" checkout <merge-sha>`, `git -C "$parent" add "$sm_path"`. When that checkout cannot fetch the child at all (proxy scope, a private child), the gitlink can still be staged without one — `git -C "$parent" update-index --cacheinfo 160000,<merge-sha>,"$sm_path"` — and on that route the containment check is the *only* thing standing between you and a pointer that dangles for everyone who clones, so it is not optional there.
5. **Commit, push, PR.** Commit with the message step 3 of the cycle uses (`Bump <name> pointer: <what the child PR did>`). That is deliberately richer than the sweep's, not identical to it: `scripts/sync/push.sh` batches every pointer it records in one repo into a single `Bump submodule pointer(s): <comma-joined paths>`, which cannot name what any child PR did because the sweep does not know. A bump made by request does know — say it. Push the branch from step 2, open the PR, and cross-link it to the child's PR in both bodies.
6. **Merging it is the maintainer's call**, like every other merge in this skill: the child's go-ahead does not carry to the parent, and the boundary does not move. Which makes this the **normal** terminal state of a `ship merge` — child merged, parent PR open, and the parent's default branch still recording the **pre-merge** pointer. Report it in exactly those terms, by name and by SHA: `<parent>` still records `<old-sha>`, the PR that moves it to `<merge-sha>` is `<url>`, and nothing moves it until that merges. A report that omits this line claims a convergence that has not happened.

**Then close the loop upward.** The parent you just opened a PR against is itself a repo that ships: read its own declaration (Phase 1 step 3 — `docs/work/consumed-by.md`) and run this cycle for anything it declares — but only **after** that parent's PR merges, because recording its PR-branch SHA one level up is the same violation as recording the child's. While the parent's PR is open, its own declared parents are named, deferred entries in the report, not PRs. The depth is whatever the declarations say: a shared package → each client that mounts it → each of those clients' own superprojects is the shape that reaches two levels, and nothing stops a third.

**Declined, or `add_repo` stayed blocked?** Then say what it costs, in the report: the parent still records the pre-merge pointer — name it, print both SHAs — and nothing records it until either a workspace-wide sweep or a later `ship` run with that parent does. Where the maintainer has a status sweep, that is what will keep reporting the lag in the meantime. Report the child as shipped and the parent as pending, never the pair as done.

## Failure modes

- **CI red on a PR** — fix on the same branch and push; the PR updates in place. Do not open a second PR for the fix.
- **Superproject branch behind its default** — fetch and rebase, then run `git submodule update` immediately: a rebase that moves pointers leaves submodule working trees stale, which can wedge the rebase itself (llmkit-dev kaizen, 2026-07-13).
- **Gitlink conflict on rebase** (a parallel task's pointer bump landed on the default branch first) — the resolution is always the SHA that is **later** on the submodule's default branch: `git -C <sm> fetch origin`, then keep whichever of the two SHAs contains the other (`git -C <sm> merge-base --is-ancestor <A> <B>`; exit 0 means B is later), `git add <sm>`, continue the rebase, `git submodule update`. Never resolve to the earlier SHA: that moves the pointer *backwards*, and a reachability check alone stays green while the superproject quietly regresses (llmkit-dev near-miss, 2026-07-17 — its pointer check now fails backwards moves mechanically).
- **Child merged, parent never finished** — for a *declared* parent this is no longer where a ship lands by default: Phase 1 plans the bump and [Phase 7's unattached-parent cycle](#the-unattached-parent) runs it and says how to report what is left. The asymmetry that belongs only here: a *lagging* pointer is fine, an *unreachable* one is not — that is what the pointer discipline exists for, and it is why a lag may be left but a dangling gitlink may not. **Assume nothing catches a lag up on its own.** An automated pointer roll is a thing a repo can configure, and it is exactly the kind of thing that gets retired without the skill hearing about it — so a lag waits for a workspace-wide sweep or a later `ship` run with that parent, and waiting is never the plan. Where a repo genuinely does roll its own pointer, that is a fact about that repo, to be confirmed there rather than remembered here.

## Hard "do NOT" list

- **Do NOT merge anything without the maintainer's go-ahead in the current conversation.** Opening PRs is autonomous; merging is not. The single recorded exception is the docs-only delegation (Phase 6): a docs-only PR in a repo that documents the fast lane merges without a per-PR go-ahead — nothing else does.
- **Do NOT record a pointer to a PR-branch SHA** — not even temporarily, not even on a branch.
- **Do NOT arm an insurance timer behind a live PR subscription**, and do NOT re-issue a scheduling call that was rejected or errored. Every one of those calls is a permission prompt on the maintainer's phone, and neither buys a return path the session does not already have.
- **Do NOT report a ship as complete while a declared parent still records the pre-merge pointer** without naming that parent, its current SHA, and why it was left — a strike-out, a blocked `add_repo`, **or** a parent PR still open awaiting the maintainer's merge, which is the *normal* end of a `ship merge` and the easiest of the three to skip past. Unqualified "shipped" reads as "every consumer is current", which is a claim about repositories this session never opened.
- **Do NOT push submodule work directly to its default branch** from a PR-flow session, even where the proxy would allow it.
- **Do NOT tag, release, or publish** — out of scope; see the workspace's release runbook.
