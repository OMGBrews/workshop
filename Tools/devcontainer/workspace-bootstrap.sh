#!/bin/bash
# Populate an empty volume-mounted workspace, then hand off to the project's
# in-repo lifecycle script. See docs/planning/volume-workspaces-plan.md (a
# private-devtools-repo document, not carried by the public mirror).
#
# Usage: workspace-bootstrap.sh <create|start> [repo-url]
#
# The repo URL normally comes from WORKSPACE_REPO_URL (set in the project's
# devcontainer.json containerEnv), so the lifecycle wiring is identical across
# all projects (the legacy `<repo-url> <create|start>` argument order from
# already-built images is still accepted):
#
#   "containerEnv":      { "WORKSPACE_REPO_URL": "<https-clone-url>" },
#   "postCreateCommand": "bash /usr/local/bin/workspace-bootstrap.sh create",
#   "postStartCommand":  "bash /usr/local/bin/workspace-bootstrap.sh start"
#
# The script must be COPY'd into the image at build time — on first boot the
# volume is empty, so nothing in-repo exists yet.
#
# Idempotent and self-healing: populates until the completion marker exists
# ($WS/.git/devcontainer-populate-done, written only after a successful clone);
# reclaims a root-owned volume. Lifecycle hooks can run before the IDE's git
# credential forwarding is ready, so the clone is retried before it gives up.
#
# A clone that never succeeds exits NON-ZERO, in both lifecycle phases. It used
# to exit 0 so the container still came up, but that made a failed populate
# indistinguishable from a good one to anything scripted. Self-healing survives
# the change: the container still exists after a failed create phase, and the
# start phase retries the populate, so reopening it once credentials exist
# completes the clone. The create-phase handoff is tracked with a marker so a
# start-phase run finishes a populate the create phase couldn't.
set -uo pipefail

case "${1:-}" in
    http://*|https://*|git@*|ssh://*)
        # Legacy argument order: <repo-url> <create|start>
        REPO_URL="$1"
        LIFECYCLE="${2:-create}"
        ;;
    *)
        LIFECYCLE="${1:-create}"
        REPO_URL="${2:-${WORKSPACE_REPO_URL:-}}"
        ;;
esac
if [ -z "$REPO_URL" ]; then
    echo "[bootstrap] No repository URL: set WORKSPACE_REPO_URL in containerEnv or pass it as an argument."
    exit 1
fi
WS="${WORKSPACE_DIR:-/workspace}"
MARKER="$WS/.git/devcontainer-post-install-done"
POPULATE_MARKER="$WS/.git/devcontainer-populate-done"
# The lock and in-progress flag live OUTSIDE $WS on purpose: the debris-clear
# and the clone itself would unlink an in-tree lockfile, and a second process
# would then lock a fresh inode while the first still holds the old one — both
# proceed, and the serialization is gone. /tmp is 1777 and container-local, so
# every seam (postCreate, postStart, shell hook) and every user (root hooks vs
# vscode shells — a consumer image can end USER root with no remoteUser)
# addresses the same path. The paths are env-overridable so the test suite can
# isolate each run.
LOCK="${WORKSPACE_BOOTSTRAP_LOCK:-/tmp/workspace-bootstrap.lock}"
FLAG="${WORKSPACE_BOOTSTRAP_FLAG:-/tmp/workspace-bootstrap-in-progress}"

# Fresh named volumes are born root-owned; reclaim before writing anything.
if [ ! -w "$WS" ]; then
    echo "[bootstrap] $WS is not writable — reclaiming ownership"
    sudo chown "$(id -un):$(id -gn)" "$WS"
fi

# Serialize the populate across the three invocation seams. The lock is held on
# fd 9 for the whole section below — flock locks the open file description, so
# the lock survives the flock process exiting and is only released when fd 9 is
# closed (flock -u, or the script exiting). The write-open can fail EACCES when
# an earlier invocation as another user created the file (root hook vs vscode
# shell); the read-open fallback locks the same inode fine, and the file is
# created 0644, so both users reach it. (Residual, accepted: a foreign 0600
# file from umask 077 — no fleet image uses that umask.)
exec 9>"$LOCK" 2>/dev/null || exec 9<"$LOCK"
flock -n 9 || { echo "[bootstrap] Populate already in progress — waiting for it to finish."; flock 9; }

# Guard on the completion marker, not on .git: git clone creates .git first and
# fills the worktree after, so .git presence is not "populated" and a clone that
# was interrupted mid-flight is not "done". The marker is written only after a
# clone that succeeded, by the bootstrap itself.
if [ ! -e "$POPULATE_MARKER" ]; then
    NEED_CLONE=1
    if [ -e "$WS/.git" ]; then
        if [ -e "$FLAG" ]; then
            echo "[bootstrap] Interrupted populate detected — clearing and re-cloning."
            rm -rf "$WS"/* "$WS"/.[!.]* "$WS"/..?* 2>/dev/null || true
        else
            echo "[bootstrap] Populated workspace predates the completion marker — recording it."
            touch "$POPULATE_MARKER"
            NEED_CLONE=0
        fi
    elif [ -n "$(ls -A "$WS" 2>/dev/null)" ]; then
        echo "[bootstrap] $WS is non-empty but has no .git — refusing to clone over it."
        echo "[bootstrap] Inspect it, clear it, then rerun: workspace-bootstrap.sh $LIFECYCLE"
        exit 0
    fi
    if [ "$NEED_CLONE" -eq 1 ]; then
        rm -f "$FLAG" 2>/dev/null; touch "$FLAG"
        echo "[bootstrap] Empty workspace — cloning $REPO_URL"
        # On a first boot the shell hook can fire before the IDE's git credential
        # machinery is ready (the askpass socket appears a few seconds after attach,
        # once extensions finish installing) — so retry rather than fail one-shot.
        #
        # GIT_TERMINAL_PROMPT=0 disables git's interactive fallback and nothing else:
        # credential helpers and GIT_ASKPASS still run, so an attached editor's
        # forwarded credentials work exactly as before. Without it, a context that
        # has a terminal but no credentials — `devcontainer up` from a plain shell —
        # prints "Username for 'https://github.com':" and waits forever, invisibly
        # whenever output is captured (observed 2026-07-31: half an hour of a fleet
        # rebuild spent watching a container that looked busy and was asking a
        # question).
        #
        # The clone is piped through tee so the failure branch can read what git
        # actually said. That pipe hides stderr's terminal from git, which would
        # silently drop the progress meter an interactive first boot shows today —
        # so ask for it explicitly, but only where it was going to appear anyway.
        # Forcing it unconditionally would stuff thousands of \r updates into every
        # captured `devcontainer up` log, which is a change to the success path.
        PROGRESS=()
        [ -t 2 ] && PROGRESS=(--progress)
        CLONE_LOG="$(mktemp)"
        CLONED=""
        for attempt in 1 2 3; do
            if GIT_TERMINAL_PROMPT=0 git clone "${PROGRESS[@]}" --recursive "$REPO_URL" "$WS" 2>&1 | tee "$CLONE_LOG"; then
                CLONED=1
                break
            fi
            # A failed clone can leave partial contents that would block the next try.
            rm -rf "$WS"/* "$WS"/.[!.]* "$WS"/..?* 2>/dev/null || true
            if [ "$attempt" -lt 3 ]; then
                echo "[bootstrap] Clone attempt $attempt failed — retrying in 5s (credentials may still be initializing)..."
                sleep 5
            fi
        done
        if [ -n "$CLONED" ]; then
            rm -f "$CLONE_LOG"
            echo "[bootstrap] Clone complete."
            touch "$POPULATE_MARKER"
            rm -f "$FLAG"
        else
            echo "[bootstrap] Clone of $REPO_URL failed after 3 attempts."
            # Two causes dominate and they need opposite advice, so read the last
            # attempt's own words rather than guessing; anything unrecognized falls
            # through to a message that covers both and quotes what git said.
            if grep -qiE 'terminal prompts disabled|could not read (Username|Password)|Authentication failed|Invalid username or (password|token)' "$CLONE_LOG"; then
                echo "[bootstrap] Cause: no usable git credentials in this context — either none"
                echo "[bootstrap]        arrived, or the ones that did were rejected. (git's interactive"
                echo "[bootstrap]        prompt is disabled here, so a clone fails rather than waiting"
                echo "[bootstrap]        forever for a username nobody is there to type.)"
                echo "[bootstrap] Ways forward:"
                echo "[bootstrap]   1. Attach an editor (VS Code / Windsurf) and open a terminal in the"
                echo "[bootstrap]      container — it forwards the host's git credentials."
                echo "[bootstrap]   2. In a container terminal, hand gh the fleet token on stdin:"
                echo "[bootstrap]        gh auth login --with-token   # paste the token, then Ctrl-D"
                echo "[bootstrap]      then rerun:  workspace-bootstrap.sh $LIFECYCLE"
                echo "[bootstrap]      Do not use the interactive device flow in a container."
                echo "[bootstrap]      GitHub keeps only ten OAuth tokens per user and application,"
                echo "[bootstrap]      so each device flow login silently revokes the oldest — which"
                echo "[bootstrap]      on a multi-container fleet is another container's."
                echo "[bootstrap]   3. Scripted rebuild with no editor, from the host:"
                echo '[bootstrap]      devcontainer up --remove-existing-container --remote-env GH_TOKEN="$(gh auth token)" --workspace-folder .'
                echo "[bootstrap]      Keep --remove-existing-container: without it the CLI reuses this"
                echo "[bootstrap]      container, skips every lifecycle hook, and reports success having"
                echo "[bootstrap]      populated nothing."
            elif grep -qiE 'Repository not found|does not appear to be a git repository' "$CLONE_LOG"; then
                echo "[bootstrap] Cause: the remote reports no such repository. For a private repo the"
                echo "[bootstrap]        answer is identical whether the URL is wrong or the credentials"
                echo "[bootstrap]        in use cannot see it, so check both:"
                echo "[bootstrap]   1. WORKSPACE_REPO_URL in .devcontainer/devcontainer.json — this run"
                echo "[bootstrap]      used $REPO_URL"
                echo "[bootstrap]   2. that the account or token behind those credentials has access to it."
            else
                echo "[bootstrap] Cause: unrecognized clone failure. The last attempt said:"
                sed 's/^/[bootstrap]   | /' "$CLONE_LOG"
                echo "[bootstrap] Check that $REPO_URL is right and reachable, and that this container"
                echo "[bootstrap] has credentials (attach an editor, or gh auth login --with-token, or"
                echo "[bootstrap] pass a token:"
                echo '[bootstrap] devcontainer up --remove-existing-container --remote-env GH_TOKEN="$(gh auth token)" --workspace-folder .).'
            fi
            echo "[bootstrap] The workspace is still empty; the next container start retries the"
            echo "[bootstrap] populate, so fixing the cause above and restarting is enough."
            rm -f "$FLAG"    # a failed clone must not look like an interrupted one
            rm -f "$CLONE_LOG"
            exit 1
        fi
    fi
fi
# Clean a flag orphaned by a crash between touch and rm; the marker outlives it.
[ -e "$POPULATE_MARKER" ] && rm -f "$FLAG"
flock -u 9

# Hand off to the project's lifecycle scripts, which exist now that the tree does.
# post_install runs once per populated workspace (marker in .git, which is never
# swept by git operations); post_start runs on every start after that.
run_post_install() {
    if [ -f "$WS/.devcontainer/scripts/post_install.sh" ]; then
        bash "$WS/.devcontainer/scripts/post_install.sh" && touch "$MARKER"
    else
        touch "$MARKER"
    fi
}

case "$LIFECYCLE" in
    create)
        run_post_install
        ;;
    start)
        [ -f "$MARKER" ] || run_post_install
        if [ -f "$WS/.devcontainer/scripts/post_start.sh" ]; then
            bash "$WS/.devcontainer/scripts/post_start.sh"
        fi
        ;;
    *)
        echo "[bootstrap] unknown lifecycle '$LIFECYCLE' (want create|start)"
        exit 1
        ;;
esac
