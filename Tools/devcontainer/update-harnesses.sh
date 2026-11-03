#!/usr/bin/env bash
#
# update-harnesses.sh — update every coding harness this kit installs, and report
# what happened to each one.
#
#   bash workshop/Tools/devcontainer/update-harnesses.sh      # from the project root
#
# Deliberately OUTSIDE build/. Everything in build/ is COPYed into images and runs at
# image-build time; this runs at RUNTIME, from the mounted Workshop checkout, so it reaches
# a container the moment a pointer moves rather than at the next rebuild. Baking it would
# freeze the update tool into the image whose contents it exists to update.
#
# Human-invoked, directly or through the update-harnesses alias installed by setup.sh.
# Never run by a startup hook, which keeps the exit-code contract below safe.
#
# ── Exit code ───────────────────────────────────────────────────────────────────────
# 0 only when every harness ended `updated` or `already-current`. Non-zero when any
# harness is `failed` OR `unavailable` — "cannot be performed" is a failure to update,
# not a pass. An absent harness is a real finding here: this kit installs all three at
# build time, so a missing one means the container predates the multi-harness kit (or a
# build silently lost it), and the remedy is printed beside the result.
#
# ── It always visits all three ──────────────────────────────────────────────────────
# No `set -e` short-circuit around the per-harness work: a partial report is the failure
# mode this script exists to avoid. One harness failing must not hide the state of the
# other two, so each is run, classified, and recorded, and the verdict is computed at
# the end from the whole table.

set -uo pipefail

# The harnesses this kit knows how to update, as `binary|label|update command`.
#
# Kept here rather than read from build/harness-*.sh: those files run at build time and
# say how to INSTALL a harness, while this says how to UPDATE one, and the two use
# different mechanisms (curl installer vs the tool's own updater). A harness added to the
# kit needs a line here — which tests/test-update-harnesses.sh asserts, so the pairing is
# checked rather than remembered.
HARNESSES=(
    "claude|Claude Code|claude update"
    "omp|Oh My Pi|omp update"
    "codex|Codex|codex update"
)

# Where the build-time kit records what it installed. Read only to improve the diagnosis
# for an `unavailable` harness — never to decide whether to try one, because a harness
# installed by hand after the build is still updatable and deserves the attempt.
HARNESS_MANIFEST="${HARNESS_MANIFEST:-$HOME/.devcontainer-harnesses}"

# Mirrors build/lib.sh's harness_locate. These installers put their binary in a
# user-local bin directory, so a non-interactive shell can have the tool on disk and off
# PATH; reporting that as `unavailable` would be a false failure.
locate_harness() {
    local binary="$1" dir found
    if found="$(command -v "$binary" 2>/dev/null)"; then
        printf '%s\n' "$found"
        return 0
    fi
    for dir in "$HOME/.local/bin" "$HOME/.codex/bin" "$HOME/bin" /usr/local/bin; do
        if [ -x "$dir/$binary" ]; then
            printf '%s\n' "$dir/$binary"
            return 0
        fi
    done
    return 1
}

results=()   # "status|label|detail", one per harness, in HARNESSES order
log_dir="$(mktemp -d)"
trap 'rm -rf "$log_dir"' EXIT

echo "=== Updating coding harnesses ==="
echo

for entry in "${HARNESSES[@]}"; do
    IFS='|' read -r binary label update_cmd <<< "$entry"

    if ! locate_harness "$binary" >/dev/null; then
        detail="not installed — re-run the build-time setup live:"
        detail="$detail bash workshop/Tools/devcontainer/build/setup.sh"
        results+=("unavailable|$label|$detail")
        printf '%-14s %s\n' "$label" "UNAVAILABLE ($binary is not installed)"
        continue
    fi

    log="$log_dir/$binary.log"
    read -r -a update_argv <<< "$update_cmd"
    # Redirect first, then read — never pipe the updater through tail. A pipeline reports
    # the PIPE's status, so a failed update would be classified from a successful `tail`.
    # This is docs/signal-hygiene.md's rule, and it is load-bearing here because the exit
    # code is the primary classifier. The braces are load-bearing too: without them the
    # redirect binds to the update command alone and the verdict lands on the terminal
    # instead of in the file this script goes on to read.
    { "${update_argv[@]}"; echo "UPDATE_EXIT=$?"; } > "$log" 2>&1
    rc="$(sed -n 's/^UPDATE_EXIT=//p' "$log" | tail -1)"
    rc="${rc:-1}"

    if [ "$rc" -ne 0 ]; then
        results+=("failed|$label|$update_cmd exited $rc")
        printf '%-14s %s\n' "$label" "FAILED (exit $rc)"
        sed 's/^/                 /' "$log"
        continue
    fi

    # Exit 0 splits two ways, and only the tool's own output can say which. Every one of
    # these updaters reports "already up to date" style text on a no-op and names a
    # version on a real update, so the distinction the acceptance criteria ask for is
    # read from the output — but a zero exit is a SUCCESS either way, so an unrecognised
    # wording degrades to `updated`, never to `failed`. Guessing wrong between two
    # success states costs a word in a report; guessing wrong about success costs trust
    # in the exit code.
    if grep -qiE 'already[- ](up[- ]to[- ]date|current|on the latest)|no update|up to date|latest version' "$log"; then
        results+=("already-current|$label|no new version")
        printf '%-14s %s\n' "$label" "already current"
    else
        results+=("updated|$label|$(grep -viE '^UPDATE_EXIT=' "$log" | grep -v '^[[:space:]]*$' | tail -1)")
        printf '%-14s %s\n' "$label" "UPDATED"
        sed '/^UPDATE_EXIT=/d' "$log" | sed 's/^/                 /'
    fi
done

echo
echo "=== Result ==="
failed=0
unavailable=0
for row in "${results[@]}"; do
    IFS='|' read -r status label detail <<< "$row"
    printf '  %-16s %-14s %s\n' "$status" "$label" "$detail"
    [ "$status" = failed ] && failed=$((failed + 1))
    [ "$status" = unavailable ] && unavailable=$((unavailable + 1))
done

if [ -r "$HARNESS_MANIFEST" ] && [ "$unavailable" -gt 0 ]; then
    echo
    echo "  This image's build-time kit recorded: $(tr '\n' ' ' < "$HARNESS_MANIFEST")"
fi

echo
if [ "$failed" -eq 0 ] && [ "$unavailable" -eq 0 ]; then
    echo "All ${#results[@]} harness(es) are current."
    exit 0
fi
echo "$failed failed, $unavailable unavailable, out of ${#results[@]} harness(es)."
exit 1
