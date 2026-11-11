# Workshop devcontainer kit

This directory contains the reusable devcontainer build and connection helpers
for Workshop consumers. It deliberately contains no maintainer identity,
private fleet registry, client inventory, or rollout state.

## Consumer contract

Copy `install-packages.sh` during the root build phase, then copy the complete
`build/` directory and run `setup.sh` after switching to the non-root user.
Copy the directory, not selected files: the setup script discovers harnesses
and its scripts resolve siblings beside it. A generic host-side connection
helper is available as `connect.sh`.

The root package phase supplies Python 3 for the launcher installer, startup
finalizer, and launcher runtime. A consumer that needs a specific Python
version installs it with `install-toolchain.sh`, described next. Dev Container
features layer on after the Dockerfile and cannot supply dependencies to
`build/setup.sh`.

## Git LFS, Python, and Ruby without keyservers

`install-toolchain.sh` installs Git LFS, and on request Python and Ruby, from
exact upstream releases whose SHA-256 digests are written in the script. Use
it in place of the `git-lfs`, `python`, and `ruby` Dev Container features.
Those features fetch GPG keys from public keyservers during the build, so a
keyserver outage stops every image from building; this script contacts none.

Copy and run it directly after `FROM`, as root:

```dockerfile
COPY workshop/Tools/devcontainer/install-toolchain.sh /tmp/install-toolchain.sh
RUN bash /tmp/install-toolchain.sh --python 3.13
```

It is a single file, so its layer is rebuilt only when the script itself
changes. Placed first, it is unaffected by changes to `build/` or to the
consumer's own files, which reinstall every feature.

| Argument | Effect |
|---|---|
| none | Install Git LFS only |
| `--python <minor>` | Also install that Python series from a prebuilt standalone release |
| `--ruby <minor>` | Also build that Ruby series from source with a pinned `ruby-build` (several minutes) |
| `--no-git-lfs` | Skip Git LFS |
| `--user <name>` | Owner of the interpreter trees; defaults to the account with UID 1000 |

Interpreters land in `/usr/local/python/<version>` and
`/usr/local/ruby/<version>`, each with a `current` link, and their main
commands are linked into `/usr/local/bin`. Commands added later by
`pip install` or `gem install` land in the tree's own `bin`; put that on the
image PATH when they are needed:

```dockerfile
ENV PATH="/usr/local/python/current/bin:/usr/local/ruby/current/bin:${PATH}"
```

Remove the matching features, and their `devcontainer-lock.json` entries, in
the same change that adds these lines. The Python feature also installed
linters and test runners such as `pytest` and `black` on PATH; this script
does not, so a project that used those installs them itself.

A requested series with no pin fails before anything is downloaded. To move a
pin, edit the PINS section of the script with the new version and the digests
from the upstream release's checksum file, then build one image per
architecture. `bash tests/test-install-toolchain.sh` covers the digest check
and install layout offline; it does not download the pinned releases, so only
an image build shows that a new pin resolves.

Setup writes Git defaults to `~/.config/git/config`, leaving `~/.gitconfig`
available for the host identity copy. The runtime validator reads Git's merged
global scope, preserving host precedence across both files while rejecting
repository-local substitutes for missing global configuration.

Consumers that use a volume workspace may copy `workspace-bootstrap.sh` and
their own project-local lifecycle wrapper. The public kit receives paths and
environment values from that consumer; it does not read HQ records or assume a
particular workspace checkout layout.

## Updating coding assistants

Setup installs an `update-harnesses` alias in both Bash and Zsh startup files.
Run it interactively to update each installed assistant and see its result.
It runs the updater from the mounted Workshop checkout, resolving
`WORKSPACE_DIR` when invoked and falling back to `/workspace`. Re-running
setup preserves an existing alias with that name.

For non-interactive callers, invoke the script explicitly:

```bash
bash "${WORKSPACE_DIR:-/workspace}/workshop/Tools/devcontainer/update-harnesses.sh"
```

The updater runs only on request; shell startup installs the alias without
running updates. A failed or unavailable assistant produces a non-zero exit
after all assistants have been reported.

## Claude ancestor-rule exclusions

The Claude harness installs `build/claude-launcher.py` as
`~/.local/share/workshop/bin/claude`. To adopt it, put that directory before
the native CLI on the container's **image PATH**, including for non-interactive
shells. For an image whose user is `vscode`, after selecting that user:

```dockerfile
ENV PATH="/home/vscode/.local/share/workshop/bin:${PATH}"
```

Rebuild and confirm `command -v claude` selects the launcher, while
`claude --version` and `claude update` reach the unchanged native installation.
The existing `cc` alias calls the same launcher. Installing the file alone or
setting PATH only in a shell rc file does not establish adoption.

After all harness installers finish, `build/finalize-claude.sh` restores the
launcher prefix at the end of Bash, Zsh, and login startup files. This ordering
matters because another installer or the default profile can prepend
`~/.local/bin` and shadow the image PATH. Existing startup content and symlinks
are preserved; no higher-priority login file is created. Verify both a fresh
interactive terminal and a non-interactive command after rebuilding.

At each local launch, the launcher finds the current Git checkout and checks
its generated standing-rule links. For each rule supplied by that checkout,
it excludes only generated ancestor links to that rule, using exact escaped
paths under `.claude/rules/`. It passes those paths through native
`--settings` before instruction loading; it never writes checkout or user
settings. Separate processes can therefore use different bind-mount layouts
without overwriting each other's exclusions. Clean libraries without their own
links inherit their ancestor rules. Partial rule sets replace only the rules
they supply. Real topic files and arbitrary user symlinks remain untouched.

Caller `--settings` JSON objects and files retain their keys and explicit
exclusions. The last supplied value wins, as in the native CLI; invalid JSON
fails visibly. Other settings layers still merge in Claude. Maintenance
commands, help/version, safe/bare modes, and cloud/desktop launch flags pass
through. An explicit native executable path bypasses PATH and this launcher.
New worktrees created by `claude --worktree` change the directory after the
launcher computes paths; this launcher does not establish deduplication for
that separate layout. Launch from an already-created checkout instead.

Run `bash tests/test-claude-launcher.sh` from the Workshop root for argument
and preservation regressions. Before adopting, capture fresh interactive
`/context` output in nested, parent-root, and standalone layouts, with external
imports approved for the trusted checkouts. Without that approval, print mode
can silently omit ancestor symlink imports and resemble a successful fix.
Static conformance and mock-CLI tests do not establish runtime loading.

## Maintainer boundary

The kit is contributor-neutral: it never sets a Git identity. Private overlays,
fleet templates, and rollout decisions belong to the consuming private control
plane, not to Workshop or this directory.
