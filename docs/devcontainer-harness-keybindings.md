# Devcontainer harness keybindings

How Workshop configures prompt entry for Claude Code, Codex, and Oh My Pi in
devcontainers. Read this when building a container, applying the configuration to a
running container, or setting up the host terminal that carries modified Enter keys.

## The shared behavior

The devcontainer build kit gives all three harnesses the same prompt-entry behavior:

- `Enter` inserts a newline.
- `Shift+Enter` submits the prompt.

The harness scripts merge these mappings into the existing user configuration rather
than replacing unrelated settings:

| Harness | Container configuration | Source |
|---|---|---|
| Claude Code | `~/.claude/keybindings.json` | `Tools/devcontainer/build/harness-claude.sh` |
| Codex | `~/.codex/config.toml` | `Tools/devcontainer/build/harness-codex.sh` |
| Oh My Pi | `~/.omp/agent/keybindings.yml` | `Tools/devcontainer/build/harness-omp.sh` |

The files under `~/` are container state; do not rely on them surviving replacement of
the container. During an image build, `Tools/devcontainer/build/setup.sh` runs all three
harness scripts and recreates the mappings. That build script is the durable source.

## Apply it to a running container

After the project has advanced its pinned Workshop checkout to a commit containing the
keybinding support, run this from the project root:

```bash
bash workshop/Tools/devcontainer/build/setup.sh
bash workshop/Tools/devcontainer/validate_setup.sh
```

The first command is safe to repeat and applies the same setup used during an image
build, without requiring a rebuild. The second checks the installed configuration.
A project pinned to an older Workshop commit still has the older setup script; move the
pin through the project's normal update process before relying on this command.

A live application fixes the current container. Durability still comes from the pinned
Workshop source and the next image build, which will recreate the files if the container
is replaced.

## Configure VS Code once on the host

A terminal must encode `Shift+Enter` distinctly from `Enter`. For VS Code's integrated
terminal, open **Preferences: Open Keyboard Shortcuts (JSON)** on the host and add this
entry to the top-level array:

```json
{
  "key": "shift+enter",
  "command": "workbench.action.terminal.sendSequence",
  "args": { "text": "\u001b[13;2u" },
  "when": "terminalFocus"
}
```

VS Code's keyboard-shortcuts file belongs to the host profile, outside the container,
so it survives container rebuilds and applies to every integrated terminal opened by
that profile. It does not automatically follow the user to another computer unless VS
Code Settings Sync includes keyboard shortcuts; otherwise configure it once on each
host.

This host setting is not part of Workshop pointer propagation. A fleet update delivers
the container-side mappings; each physical host or synced VS Code profile owns its
terminal encoding separately.
