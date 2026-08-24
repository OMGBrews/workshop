#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib.sh — helpers shared by the neutral setup.sh and every harness-*.sh beside it.
#
# Sourced, never executed. Deliberately NOT named harness-*.sh: setup.sh discovers
# harnesses by globbing `harness-*.sh` in this directory, so a helper file matching
# that glob would be run as a harness and "configure" one that does not exist.

# The baked harness manifest: one harness name per line, written at image build and
# read at container start by validate_setup.sh.
#
# It exists because install and validation happen at different times. Installs land at
# REBUILD; validate_setup.sh runs live off the mounted devtools clone at EVERY container
# start, so it updates the moment a pointer moves. A validator that simply asserted
# "omp is present" would therefore fail in every consumer whose image predates this
# change — the whole fleet, at its next container start, for a rebuild nobody has done
# yet. Gating on the manifest inverts that: the validator asserts only what the image in
# front of it claims to have installed, and an image with no manifest is a pre-change
# image whose Claude-only checks are exactly right.
HARNESS_MANIFEST="${HARNESS_MANIFEST:-$HOME/.devcontainer-harnesses}"

# The shell startup files a harness may write an alias into. Both, always: the container
# base image ships zsh as the login shell while every `#!/usr/bin/env bash` script and a
# plain `docker exec` get bash, so an alias written to one is missing from the other
# half the time.
harness_rcfiles() {
    printf '%s\n' "$HOME/.bashrc" "$HOME/.zshrc"
}

# harness_record <name> — record that this harness was installed and configured.
#
# Called by a harness script only after its install has actually succeeded. Recording it
# earlier would bake a claim the image does not honour, and the validator would then
# assert a harness that is not there — turning the manifest from a description of the
# image into a wish.
harness_record() {
    local name="$1"
    mkdir -p "$(dirname "$HARNESS_MANIFEST")"
    if [ -f "$HARNESS_MANIFEST" ] && grep -qxF "$name" "$HARNESS_MANIFEST"; then
        return 0
    fi
    printf '%s\n' "$name" >> "$HARNESS_MANIFEST"
}

# harness_alias <name> <full alias line> — install a launch shortcut in both rc files.
#
# Idempotent on the alias NAME rather than on the whole line, so a human who has
# re-pointed `cc` at something of their own keeps it across a re-run. setup.sh is
# re-run inside live containers, and silently reverting someone's edit on every run is
# the kind of change that is only ever noticed long after it happened.
harness_alias() {
    local name="$1" line="$2" rcfile
    while IFS= read -r rcfile; do
        if [ -f "$rcfile" ] && grep -qF "alias $name=" "$rcfile"; then
            continue
        fi
        printf '%s\n' "$line" >> "$rcfile"
    done < <(harness_rcfiles)
}

# harness_upsert_toml_key <file> <section> <key> <TOML value>
#
# Replace one key in one TOML table without taking ownership of the rest of the file.
# Harness config is user config too: setup.sh is safe to re-run in a live container, so
# overwriting config.toml to install one shared default would destroy model, provider,
# MCP, and UI preferences that have nothing to do with the build kit.
harness_upsert_toml_key() {
    local file="$1" section="$2" key="$3" value="$4" tmp
    mkdir -p "$(dirname "$file")"
    [ -e "$file" ] || : > "$file"
    tmp="$(mktemp)"
    awk -v section="$section" -v key="$key" -v value="$value" '
        function emit_key() {
            if (!key_emitted) {
                print key " = " value
                key_emitted = 1
            }
        }

        /^[[:space:]]*\[[^][]+\][[:space:]]*(#.*)?$/ {
            if (in_section) emit_key()
            header = $0
            sub(/^[[:space:]]*\[/, "", header)
            sub(/\][[:space:]]*(#.*)?$/, "", header)
            in_section = (header == section)
            if (in_section) section_seen = 1
            print
            next
        }

        {
            candidate = $0
            sub(/^[[:space:]]*/, "", candidate)
            if (in_section && substr(candidate, 1, length(key)) == key) {
                suffix = substr(candidate, length(key) + 1)
                if (suffix ~ /^[[:space:]]*=/) {
                    emit_key()
                    next
                }
            }
            print
        }

        END {
            if (in_section) emit_key()
            if (!section_seen) {
                if (NR > 0) print ""
                print "[" section "]"
                print key " = " value
            }
        }
    ' "$file" > "$tmp"
    mv -f "$tmp" "$file"
}

# harness_upsert_flat_yaml_key <file> <key> <YAML value>
#
# OMP's keybindings file is a flat YAML map. Support both its documented inline values
# and a user's block-style value, removing the old indented block when replacing a key.
harness_upsert_flat_yaml_key() {
    local file="$1" key="$2" value="$3" tmp
    mkdir -p "$(dirname "$file")"
    [ -e "$file" ] || : > "$file"
    tmp="$(mktemp)"
    awk -v key="$key" -v value="$value" '
        function is_target(line,    candidate, suffix) {
            candidate = line
            sub(/^[[:space:]]*/, "", candidate)
            if (substr(candidate, 1, length(key)) != key) return 0
            suffix = substr(candidate, length(key) + 1)
            return suffix ~ /^[[:space:]]*:/
        }

        skipping && /^[[:space:]]+/ { next }
        skipping { skipping = 0 }

        is_target($0) {
            if (!key_emitted) {
                print key ": " value
                key_emitted = 1
            }
            skipping = 1
            next
        }

        { print }

        END {
            if (!key_emitted) print key ": " value
        }
    ' "$file" > "$tmp"
    mv -f "$tmp" "$file"
}

# harness_locate <binary> — is this harness CLI installed? Prints its path if so.
#
# Not a bare `command -v`. Every one of these installers drops its binary in a user-local
# bin directory and then edits shell startup files to put that directory on PATH — which
# does nothing for the NON-INTERACTIVE build shell running this script, where the freshly
# installed binary is on disk and invisible to `command -v`. So search PATH first, then
# the directories the installers actually use. A false "not installed" here would make
# the guard below reinstall on every live re-run, and would make the post-install
# assertion fail a build that had in fact succeeded.
harness_locate() {
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

# harness_install_via_curl <binary> <url> <label> — install a harness CLI, once.
#
# Skipped when the binary is already present, for the reason setup.sh's Claude guard
# has always carried: this script is also re-run inside live containers to pick up
# config changes without a rebuild, and replacing a CLI binary underneath a running
# session of that same CLI is at best pointless. At image-build time nothing is
# installed yet, so the guard falls through and the install runs.
#
# Updating an already-installed harness is deliberately NOT this function's job — that
# is update-harnesses.sh, which runs each harness's own updater and reports per-harness
# results. Install-if-missing and update are different operations with different failure
# modes, and a build-time script is the wrong place to do the second.
harness_install_via_curl() {
    local binary="$1" url="$2" label="$3"
    if harness_locate "$binary" >/dev/null; then
        echo "  $label already installed (skipping)"
        return 0
    fi
    curl -fsSL "$url" | bash
    # Assert the artifact, don't trust the pipeline: `curl … | bash` reports bash's
    # status, so an installer that printed an error and exited 0 would leave this script
    # claiming an install that never happened — the decorative success
    # docs/signal-hygiene.md exists to prevent. `hash -r` because the binary landed in a
    # directory this shell may already have scanned.
    hash -r 2>/dev/null || true
    if ! harness_locate "$binary" >/dev/null; then
        echo "ERROR: $label installer ran but left no '$binary' binary anywhere this" >&2
        echo "       script looks (PATH, ~/.local/bin, ~/.codex/bin, ~/bin, /usr/local/bin)." >&2
        echo "       Installed from: $url" >&2
        return 1
    fi
    echo "  $label installed"
}
