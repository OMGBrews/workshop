#!/usr/bin/env bash
# Session bootstrap, harness-neutral: make a fresh clone of a superproject
# workable, and keep a cached cloud checkout current — a guarded fast-forward
# where that is provably loss-free, an honest staleness report everywhere else.
#
# THIS FILE IS THE BOOTSTRAP. It is a plain script: any harness, any CI job, and
# any human can run it, and its exit code and stdout are the whole contract.
#   bash scripts/agent/session-start.sh
# Claude Code reaches it through .claude/hooks/session-start.sh, a thin wrapper
# that adds nothing but the vendor's JSON envelope (see session-start.sh in this
# same template directory). Nothing below knows that wrapper exists.
#
# Canonical copy: <shared-tools mount>/docs/templates/cloud-sessions/agent-session-start.sh —
# each project carries its own copy at scripts/agent/session-start.sh, because a
# script whose job includes initializing the shared-tools tree cannot live inside
# it. The copies are promised byte-for-byte identical; the drift guard at the
# bottom of this file checks that promise — for this file and for the wrapper —
# every session.
#
# Cloud (agent sandbox) sessions clone the superproject with no submodules
# initialized, and the session's git proxy scopes repo access: public repos
# clone freely, private ones return 403 until added to the session with
# add_repo — which only the agent can do, mid-session. A batch
# `git submodule update --init --recursive` is the wrong tool here — it
# aborts on the first denied repo and can leave an earlier submodule cloned
# but not checked out (observed 2026-07-16 in a live cloud session). So: init each
# submodule separately, tolerate per-repo failure, and only touch submodules
# that are actually uninitialized — `git submodule update` on an initialized
# one would yank its checkout back to the recorded pointer, which is hostile
# on a local machine mid-task. On a fully initialized tree (any local
# checkout) this is a fast no-op.
#
# Private submodules (cloud): if the environment provides
# SUBMODULE_READ_TOKEN — a fine-grained PAT with read-only Contents access
# to the private submodule repo(s) — a failed init is retried directly
# against github.com with that token, bypassing the session proxy, so the
# shared skills and standing rules exist from the session's first turn.
# The token is for this bootstrap read only: it is scrubbed from git config
# afterwards, it is never echoed, and pushes still require add_repo. The
# environment's network policy must allow github.com for the retry to work.
#
# Environment, all optional and all harness-neutral:
#   AGENT_PROJECT_DIR             repo root; defaults to `git rev-parse --show-toplevel`
#   AGENT_SESSION_EPHEMERAL       "true" when the checkout is a disposable sandbox
#                                 restored from a snapshot — the one condition under
#                                 which this script MUTATES refs (the guarded
#                                 fast-forward) and uses SUBMODULE_READ_TOKEN.
#                                 Unset on a local machine: report only, never a reset.
#   AGENT_BOOTSTRAP_RELOAD_MARKER path to touch when this run initialized or
#                                 re-synced a submodule. A caller that caches a
#                                 skill/plugin registry built from files inside a
#                                 submodule must rebuild it when this file is
#                                 non-empty; a caller with no such cache leaves the
#                                 variable unset and nothing is written.
#   SUBMODULE_READ_TOKEN          see above.
#
# Output: ordinary report lines on stdout, one per finding, each prefixed
# `[session-start]`. Silence means checked-and-nothing-to-say — every failure
# path below prints, because a check that skips quietly is indistinguishable
# from one that passed (signal-hygiene.md). Always exits 0: this is a report,
# and no finding here is grounds for failing a session or a build.
set -u
cd "${AGENT_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" || exit 0

# Record that this run changed a submodule checkout, and so needs any
# submodule-derived registry rebuilt. Called from inside `while read` loops,
# which are pipeline subshells — a file, not a variable, is what survives that.
# With no marker requested this is a no-op, and the caller asked for nothing.
_mark_reload() {
  [ -n "${AGENT_BOOTSTRAP_RELOAD_MARKER:-}" ] && printf 'x' >> "$AGENT_BOOTSTRAP_RELOAD_MARKER"
  return 0
}

# True when the checkout is a disposable sandbox and mutating it is safe.
_ephemeral() { [ "${AGENT_SESSION_EPHEMERAL:-}" = "true" ]; }

# The shared-tools mount: the tree this kit ships in, found by discovery rather
# than by name. The fleet mounts it as devtools/; a public consumer mounts the
# Workshop mirror as workshop/; a repo may mount it under any name. The deployed
# copy of THIS script lives outside that tree (scripts/agent/), so self-location
# cannot name the mount — check the conventional names first, then every
# submodule path .gitmodules declares, for the kit marker. Absent means the
# tree is not mounted (or the pin predates the kit): the roster seam and the
# drift guard below stay silent exactly as they did before, and the init loop
# has already reported loudly why the tree is missing.
KIT_MOUNT=""
for candidate in devtools workshop; do
  if [ -f "$candidate/docs/templates/cloud-sessions/agent-session-start.sh" ]; then
    KIT_MOUNT="$candidate"; break
  fi
done
if [ -z "$KIT_MOUNT" ]; then
  while read -r _kit_key kit_path; do
    [ -n "$kit_path" ] || continue
    if [ -f "$kit_path/docs/templates/cloud-sessions/agent-session-start.sh" ]; then
      KIT_MOUNT="$kit_path"; break
    fi
  done < <(git config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null)
fi

# Freshness: a cloud session in a cached environment does NOT clone at
# session start — the workspace is restored from the environment's
# filesystem snapshot ("Environment caching" in the Claude Code on the web
# docs), which rebuilds only on a setup-script/network-config change or
# ~7-day expiry, and the session cuts its working branch from the
# snapshot's local default branch without fetching. A day-old clone misled
# a session into re-proposing an already-resolved problem from a shared
# register (observed 2026-07-18 in a live cloud session). So: fetch, and in an ephemeral
# session (AGENT_SESSION_EPHEMERAL=true) fast-forward the working branch to
# the remote default branch — but ONLY when that is provably loss-free:
# clean tree, HEAD on a branch, zero local commits, and `--ff-only` so git
# itself refuses anything that would drop history. A resumed session
# carrying commits, a dirty tree, or any local machine (no
# AGENT_SESSION_EPHEMERAL) gets the report without the mutation — acting on
# it is then the agent's job. After a fast-forward the recorded submodule
# pointers have moved, so initialized submodules are re-synced to them
# (with the same read-token fallback the init loop uses); this is the one
# deliberate exception to "never touch an initialized submodule", safe for
# the same reason the fast-forward is: session start, clean tree, no work
# yet. Skipped silently when there is no `origin` (a purely local repo has
# nothing to be stale against).

# Re-sync one already-initialized submodule to its (just-moved) recorded
# pointer, fetching via github.com with SUBMODULE_READ_TOKEN. Unlike
# init_via_token this rewrites the *submodule's own* origin URL — an
# initialized submodule fetches through its own remote, not through
# `submodule.<name>.url` in the superproject config. Token scrubbed and
# masked identically.
resync_via_token() { # <path> <clean-url>
  rvt_path="$1"; rvt_url="$2"
  rvt_authed="https://x-access-token:${SUBMODULE_READ_TOKEN}@github.com/${rvt_url#https://github.com/}"
  git -C "$rvt_path" remote set-url origin "$rvt_authed" || return 1
  rvt_out="$(git submodule update -- "$rvt_path" 2>&1)"; rvt_rc=$?
  # Only touch the submodule's OWN remote when its worktree is a real repo. If
  # the update wiped it to an empty dir, `git -C` there resolves the enclosing
  # superproject and would repoint ITS origin at the submodule URL (see
  # init_via_token). Latent here — resync runs only on initialized submodules —
  # but guarded to match.
  if [ -e "$rvt_path/.git" ]; then
    git -C "$rvt_path" remote set-url origin "$rvt_url" 2>/dev/null || true
  fi
  if [ $rvt_rc -ne 0 ]; then
    printf '%s\n' "${rvt_out//${SUBMODULE_READ_TOKEN}/***}" | tail -2
  fi
  return $rvt_rc
}

# After a superproject fast-forward, bring each initialized submodule whose
# recorded pointer moved ('+' in `git submodule status`) back in sync.
# Uninitialized ones ('-') are left for the init loop below. Per-submodule
# failure tolerance, like the init loop: a submodule that cannot fetch is
# reported loudly and left visibly modified, never aborts the rest.
resync_submodules() {
  git submodule status 2>/dev/null | while read -r rs_line; do
    case "$rs_line" in
      "+"*)
        rs_path="$(printf '%s\n' "$rs_line" | awk '{print $2}')"
        if git submodule update -- "$rs_path" >/dev/null 2>&1; then
          echo "[session-start] synced submodule to the fast-forwarded pointer: $rs_path"
          _mark_reload
          continue
        fi
        rs_key="$(git config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | awk -v p="$rs_path" '$2==p {print $1; exit}')"
        rs_name="${rs_key#submodule.}"; rs_name="${rs_name%.path}"
        rs_url="$(git config --file .gitmodules --get "submodule.$rs_name.url" 2>/dev/null || echo '?')"
        if [ -n "${SUBMODULE_READ_TOKEN:-}" ] && [ "${rs_url#https://github.com/}" != "$rs_url" ] \
           && resync_via_token "$rs_path" "$rs_url"; then
          echo "[session-start] synced submodule to the fast-forwarded pointer: $rs_path (read-token fallback)"
          _mark_reload
        else
          echo "[session-start] could NOT sync $rs_path to the fast-forwarded pointer ($rs_url) — its checkout still matches the pre-fast-forward pointer, so git status shows it modified. Fix: add_repo, then: git submodule update -- $rs_path"
        fi
        ;;
    esac
  done
}

if git remote get-url origin >/dev/null 2>&1; then
  # --prune: a squash merge deletes the remote PR branch but the local
  # remote-tracking ref survives, and downstream tooling that sizes ranges
  # off it (e.g. the platform's stop hook) then sweeps already-merged
  # history into "unpushed"/"unverified" complaints. Prune at the one seam
  # every session passes through.
  fetch_cmd=(git fetch --prune origin)
  command -v timeout >/dev/null 2>&1 && fetch_cmd=(timeout 30s "${fetch_cmd[@]}")
  # Retry with backoff. The session's git proxy finishes injecting its
  # credential a beat after the container starts, so a fetch fired at t=0 can
  # lose that race and fail immediately with "could not read Password" /
  # "terminal prompts disabled" while the identical fetch succeeds seconds
  # later. A single miss otherwise strands the checkout at snapshot age — and
  # skips the loss-free fast-forward and submodule resync below — for the WHOLE
  # session (observed 2026-07-24 in a live cloud session). The credential-race failure
  # returns fast, so the 0s/2s/4s backoff costs ~6s only when actually retrying;
  # a first-try success (the common case) adds nothing.
  fetch_ok=""
  for fetch_delay in 0 2 4; do
    [ "$fetch_delay" = 0 ] || sleep "$fetch_delay"
    if fetch_out="$("${fetch_cmd[@]}" 2>&1)"; then fetch_ok=1; break; fi
  done
  if [ -n "$fetch_ok" ]; then
    # A platform clone (init + fetch, no `git clone`) has no origin/HEAD;
    # restore it so every consumer of the default-branch name — this block,
    # the platform's stop hook — resolves it instead of guessing. Failure
    # is handled: the symbolic-ref fallback below still names origin/main.
    git symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1 \
      || git remote set-head origin -a >/dev/null 2>&1
    # symbolic-ref, not rev-parse: with origin/HEAD absent (set-head can
    # fail offline), rev-parse echoes the unresolved name to stdout before
    # failing, garbling the variable.
    remote_head="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
    branch="${remote_head#origin/}"
    if git show-ref --verify --quiet "refs/remotes/$remote_head"; then
      # Ephemeral auto-sync: fast-forward the working branch when loss-free.
      if _ephemeral \
         && head_branch="$(git symbolic-ref --quiet --short HEAD)" \
         && [ -z "$(git status --porcelain 2>/dev/null)" ]; then
        head_ahead="$(git rev-list --count "$remote_head..HEAD" 2>/dev/null || echo '?')"
        head_behind="$(git rev-list --count "HEAD..$remote_head" 2>/dev/null || echo '?')"
        if [ "$head_ahead" = "0" ] && [ "$head_behind" != "0" ] && [ "$head_behind" != "?" ]; then
          old_head="$(git rev-parse --short HEAD)"
          if sync_out="$(git merge --ff-only "$remote_head" 2>&1)"; then
            echo "[session-start] fast-forwarded $head_branch $old_head -> $(git rev-parse --short HEAD): $head_behind commit(s) from $remote_head (ephemeral session, clean tree, no local commits — loss-free by construction)"
            # Best-effort: carry the local default branch along so register
            # reads at either ref agree. Failure is handled by design — the
            # report below then states the divergence, and $remote_head
            # stays the authoritative fresh ref either way.
            [ "$head_branch" != "$branch" ] && git fetch . "$remote_head:refs/heads/$branch" >/dev/null 2>&1
            resync_submodules
          else
            echo "[session-start] fast-forward of $head_branch to $remote_head refused: $(printf '%s\n' "$sync_out" | tail -1)"
          fi
        fi
      fi
      if git show-ref --verify --quiet "refs/heads/$branch"; then
        behind="$(git rev-list --count "refs/heads/$branch..refs/remotes/$remote_head" 2>/dev/null || echo '?')"
        ahead="$(git rev-list --count "refs/remotes/$remote_head..refs/heads/$branch" 2>/dev/null || echo '?')"
        if [ "$behind" = "0" ]; then
          echo "[session-start] fetched origin: local $branch is up to date with $remote_head"
        else
          extra=""; [ "$ahead" != "0" ] && extra=" and $ahead ahead"
          echo "[session-start] fetched origin: local $branch is $behind commit(s) behind $remote_head$extra — a cached-environment clone is as old as its snapshot; read shared state (registers, task docs) at $remote_head, or rebase/reset, before selecting work"
        fi
      else
        echo "[session-start] fetched origin (no local $branch — no staleness comparison)"
      fi
    else
      echo "[session-start] fetched origin ($remote_head missing — no staleness comparison)"
    fi
  else
    err_line="$(printf '%s\n' "$fetch_out" | grep -m1 '^fatal:' || printf '%s\n' "$fetch_out" | tail -1)"
    echo "[session-start] git fetch origin FAILED after 3 attempts (2s/4s backoff) — refs are as stale as the environment snapshot. Error: $err_line"
  fi
fi

# Retry one submodule init directly against github.com using
# SUBMODULE_READ_TOKEN. Args: <name> <path> <clean-url>. The credentialed
# URL defeats the proxy's insteadOf rewrite (the userinfo breaks the
# https://github.com/ prefix match), so the fetch goes direct. The token is
# scrubbed from git config afterwards and masked in any printed output.
init_via_token() {
  ivt_name="$1"; ivt_path="$2"; ivt_url="$3"
  ivt_authed="https://x-access-token:${SUBMODULE_READ_TOKEN}@github.com/${ivt_url#https://github.com/}"
  git submodule init -- "$ivt_path" >/dev/null 2>&1 || return 1
  git config "submodule.$ivt_name.url" "$ivt_authed" || return 1
  ivt_out="$(git submodule update -- "$ivt_path" 2>&1)"; ivt_rc=$?
  git config "submodule.$ivt_name.url" "$ivt_url"
  # Scrub the token from the submodule's OWN remote — but only when the update
  # produced a checkout. On failure (e.g. the token fetch is blocked by the
  # network allowlist) the worktree is an empty dir with no .git, and `git -C`
  # there resolves the enclosing SUPERPROJECT, repointing its origin at the
  # submodule URL (observed 2026-07-19 in a live cloud session). The superproject
  # config was already scrubbed one line up; this line is the submodule's.
  if [ -e "$ivt_path/.git" ]; then
    git -C "$ivt_path" remote set-url origin "$ivt_url" 2>/dev/null || true
  fi
  if [ $ivt_rc -ne 0 ]; then
    printf '%s\n' "${ivt_out//${SUBMODULE_READ_TOKEN}/***}" | tail -2
  fi
  return $ivt_rc
}

git config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null \
| while read -r key sm_path; do
  name="${key#submodule.}"; name="${name%.path}"
  status="$(git submodule status -- "$sm_path" 2>/dev/null || true)"
  case "$status" in
    -*)
      if out="$(git submodule update --init -- "$sm_path" 2>&1)"; then
        echo "[session-start] initialized submodule: $sm_path"
        _mark_reload
        continue
      fi
      url="$(git config --file .gitmodules --get "submodule.$name.url" 2>/dev/null || echo '?')"
      if _ephemeral && [ -n "${SUBMODULE_READ_TOKEN:-}" ] \
         && [ "${url#https://github.com/}" != "$url" ]; then
        if init_via_token "$name" "$sm_path" "$url"; then
          echo "[session-start] initialized submodule: $sm_path (read-token fallback; pushing it still needs add_repo)"
          _mark_reload
        else
          echo "[session-start] could NOT initialize $sm_path ($url) even with SUBMODULE_READ_TOKEN — check the token's repo access and expiry, and that github.com is allowed by the environment's network policy. Fallback: add_repo, then: git submodule update --init $sm_path"
        fi
        continue
      fi
      echo "[session-start] could NOT initialize $sm_path ($url) — likely a private repo outside the session's scope. Fix: add the repo to the session (add_repo), then run: git submodule update --init $sm_path. Last error line: $(printf '%s\n' "$out" | tail -1)"
      ;;
    "")
      echo "[session-start] $sm_path is in .gitmodules but unknown to git — skipped (check the working tree)"
      ;;
    *)
      : # already initialized: leave the checkout alone
      ;;
  esac
done

# Parent-side pointer check: is what this superproject RECORDS for each of its
# children still that child's branch tip?
#
# Declared edges only. A .gitmodules entry carrying `branch = <name>` declares
# that the edge is meant to track that branch's tip — the edge a workspace
# sweep advances and the only kind a lag report covers. An entry with no
# `branch` key is pinned on purpose (the shared-tools tree itself is the fleet's
# example: a deliberate pin whose lag is intentional and whose only writer is
# an explicit propagation, never a session). Pinned edges are therefore silent
# here BY DESIGN, and the `branch` key is the entire discriminator — no repo is
# named and no URL is inspected to decide which is which.
#
# Why session start: since the scheduled bump bot was retired (2026-07-28)
# pointers move only when someone asks, so the one thing the model still needs
# is that the lag be visible at a moment when a human or agent is present to
# act on it. The failure that prevents is concrete — a session reading a child
# through a stale pointer sees a tree missing work that exists on the child's
# remote (observed 2026-07-21: a stale pointer hid real upstream work from a
# session).
#
# A lagging pointer is NOT a fault and this notice is not an alarm: it means
# only that nobody has asked for the upgrade yet. Read it, act or ignore.
#
# Cost and safety: the recorded gitlink (git ls-tree HEAD) against one
# `git ls-remote` per declared edge — no fetch, no clone, and no initialized
# checkout required, which is what lets it work in a fresh cloud clone where
# the child may not even be attached to the session. Nothing here mutates
# anything. Silence means checked-and-in-sync, which is only true because every
# failure path below prints: a check that skips quietly is indistinguishable
# from one that passed (signal-hygiene.md).
#
# Placed after the init loop, so a submodule initialized moments ago is checked
# in the same pass, and before the drift guard, so the drift remedy stays the
# last thing in the session's context.

# One declared edge. Prints at most two lines, mutates nothing, and always
# returns 0 — this script's exit status is not this check's to change.
report_pointer_lag() { # <path> <url> <branch>
  rpl_path="$1"; rpl_url="$2"; rpl_branch="$3"
  # The gitlink in HEAD, not `git submodule status`: the recorded pointer is
  # what anyone cloning this superproject gets, and reading it needs no checkout.
  rpl_rec="$(git ls-tree HEAD -- "$rpl_path" 2>/dev/null | awk '$2=="commit"{print $3; exit}')"
  if [ -z "$rpl_rec" ]; then
    echo "[session-start] $rpl_path is declared in .gitmodules (branch = $rpl_branch) but HEAD records no gitlink for it — nothing to compare, so its currency is unknown"
    return 0
  fi
  # GIT_TERMINAL_PROMPT=0 and the timeout wrapper for the same reason the fetch
  # above uses them: a URL wanting credentials sits at a prompt, and a bootstrap
  # that hangs at session start is worse than one that reports nothing.
  # 10s, not the fetch's 30s: an ls-remote is one ref advertisement, not a
  # transfer, and this runs once per declared edge on EVERY session start —
  # including offline local ones, where each unreachable URL pays the bound in
  # full before the session's first turn.
  rpl_cmd=(git ls-remote "$rpl_url" "refs/heads/$rpl_branch")
  command -v timeout >/dev/null 2>&1 && rpl_cmd=(timeout 10s "${rpl_cmd[@]}")
  if ! rpl_out="$(GIT_TERMINAL_PROMPT=0 "${rpl_cmd[@]}" 2>&1)"; then
    echo "[session-start] could NOT check the recorded pointer for $rpl_path against $rpl_url — ls-remote failed, so its currency is unknown, not fine (a private child outside this session's proxy scope answers 403: add_repo, then re-run). Last error line: $(printf '%s\n' "$rpl_out" | tail -1)"
    return 0
  fi
  # Take the tip only from a real advertisement OF THE REF WE ASKED FOR —
  # assert the shape, never the position. stderr is merged into $rpl_out so a
  # failure can be quoted, and git writes to stderr on SUCCESS too ("warning:
  # redirecting to https://…" on an http:// URL): first-field-of-first-line
  # then yields `warning:`, which is seven characters and so prints as a
  # plausible short SHA — a confident false lag report for an edge that is
  # provably in sync. It also keeps the no-such-branch case below reachable,
  # which an emptiness test on merged output is not. Silence means checked
  # here, so a line that only looks like a SHA must not be believed.
  rpl_tip="$(printf '%s\n' "$rpl_out" \
    | awk -v r="refs/heads/$rpl_branch" '$1 ~ /^[0-9a-f]{40}$/ && $2 == r {print $1; exit}')"
  if [ -z "$rpl_tip" ]; then
    echo "[session-start] could NOT check the recorded pointer for $rpl_path — $rpl_url has no refs/heads/$rpl_branch, the branch .gitmodules declares it tracks. Currency unknown, not fine."
    return 0
  fi
  [ "$rpl_tip" = "$rpl_rec" ] && return 0
  echo "[session-start] $rpl_path: HEAD records ${rpl_rec:0:7}, but $rpl_branch on $rpl_url is at ${rpl_tip:0:7} — work read through $rpl_path here is the recorded commit's, not the child's latest. Not a fault: pointers move only when someone asks."
  echo "[session-start]   Take it when you want it: git submodule update --init --remote -- $rpl_path && git add $rpl_path, then commit the gitlink — in a cloud session /ship with the parent attached records it; in an hq workspace ./scripts/sync/pull.sh && ./scripts/sync/push.sh does the whole fleet."
  return 0
}

git config --file .gitmodules --get-regexp 'submodule\..*\.branch' 2>/dev/null \
| while read -r pcheck_key pcheck_branch; do
  pcheck_name="${pcheck_key#submodule.}"; pcheck_name="${pcheck_name%.branch}"
  pcheck_path="$(git config --file .gitmodules --get "submodule.$pcheck_name.path" 2>/dev/null || true)"
  pcheck_url="$(git config --file .gitmodules --get "submodule.$pcheck_name.url" 2>/dev/null || true)"
  if [ -z "$pcheck_path" ] || [ -z "$pcheck_url" ]; then
    echo "[session-start] submodule.$pcheck_name declares branch $pcheck_branch but .gitmodules gives it no path/url — its recorded pointer cannot be checked"
    continue
  fi
  report_pointer_lag "$pcheck_path" "$pcheck_url" "$pcheck_branch"
done

# Repo-local sandbox extras. Credential materialization, cache wiring, and
# anything else an ephemeral session needs that is specific to THIS repo
# cannot live in this template — it is repo-specific by definition — so the
# kit chains a well-known repo-local script when one exists:
# scripts/agent/cloud-env.sh, a plain script under the same AGENT_* contract
# (the variables this script received are exported, so the child inherits
# them), self-guarded to no-op outside an ephemeral session. Chaining is what
# keeps the bootstrap ONE command: a harness or human that runs only this
# script still gets the credentials, and per-harness hook wiring stays a
# single entry. Absent is fine and says nothing — a repo with no sandbox
# secrets carries no file. Output lines keep the child's own [cloud-env]
# prefix so the report says who did what.
if [ -f scripts/agent/cloud-env.sh ]; then
  bash scripts/agent/cloud-env.sh
fi

# Skill-roster staleness seam. A running session snapshots its skill roster at
# start, and neither a manual sync nor the propagation tooling tells it when
# the skill entry set changes underneath it (Tools/check-skill-roster-
# freshness.sh names the mechanism and the per-harness evidence). Wire the
# git hooks that detect such a change, and record the session-start baseline
# they compare against: the roster is about to be built from THIS tree, so it
# is the one state a later warning can honestly call "since this session
# started". Idempotent; mutates only local git config and one file inside the
# git dir; silent when the mount or the tool is absent (an older pinned
# shared-tools tree) — the seam appears when the pointer advances, like every
# other shared-tools change.
if [ -n "$KIT_MOUNT" ] && [ -f "$KIT_MOUNT/Tools/check-skill-roster-freshness.sh" ]; then
  git config core.hooksPath "$KIT_MOUNT/Tools/hooks"
  bash "$KIT_MOUNT/Tools/check-skill-roster-freshness.sh" baseline
fi

# Drift guard: the bootstrap exists in two copies by structural necessity — the
# templates in the shared-tools tree are canonical, and every adopter carries
# deployed copies promised byte-for-byte identical (see the template README).
# Compare them every session so divergence in either direction surfaces within
# one session, in the session's own context. BOTH kit files are checked here,
# in this one always-run place: this script, and the harness wrapper that may
# or may not have invoked it. A deployed file that is absent is not drift — a
# non-Claude repo carries no wrapper — so only a present-and-different pair
# reports. When the shared-tools tree is absent the comparison is impossible;
# that is not a silent hole, because the init loop above has already said,
# loudly, why it is missing.
drift_check() { # <template-basename> <deployed-path>
  dc_tpl="$KIT_MOUNT/docs/templates/cloud-sessions/$1"; dc_dep="$2"
  [ -n "$KIT_MOUNT" ] && [ -f "$dc_tpl" ] && [ -f "$dc_dep" ] || return 0
  cmp -s "$dc_tpl" "$dc_dep" && return 0
  echo "[session-start] DRIFT: $dc_dep differs from its canonical template ($dc_tpl)."
  echo "[session-start]   The template is canonical — deliberate changes flow template -> copies."
  echo "[session-start]   If the deployed copy carries a hotfix, upstream it into the template first; then redeploy:"
  echo "[session-start]   cp $dc_tpl $dc_dep && chmod +x $dc_dep    (inspect first: diff $dc_tpl $dc_dep)"
}
drift_check agent-session-start.sh scripts/agent/session-start.sh
drift_check session-start.sh .claude/hooks/session-start.sh
exit 0
