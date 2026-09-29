# Git LFS in cloud sessions

How a repository that tracks files with Git LFS makes them readable and
pushable in a Claude Code on the Web session. Read this when a cloud checkout
holds LFS pointers, when `git lfs` reports missing credentials there, or when
adding LFS to a repository with a [Web declaration](claude-code-web.md).

## What goes wrong without it

Three independent failures, each silent or misleading:

- **The checkout holds pointers.** The platform clones without smudging, so
  every LFS-tracked file arrives as a ~130-byte text file beginning
  `version https://git-lfs.github.com/spec`. Reading one does not error; an
  importer or renderer fails later with a message that never mentions LFS.
- **git-lfs cannot authenticate, although the proxy would.** The session's
  GitHub proxy authorizes requests itself, but git-lfs asks a credential
  helper for a username and password first. When no helper answers, it fails
  with `could not read Username` or `Git credentials for https://github.com/...
  not found` before the request reaches the proxy, while plain `git fetch`
  works. It is intermittent: the platform's helper sometimes answers. The same
  probe also blocks ordinary pushes that carry no LFS objects. This looks like
  the proxy refusing LFS, and has been misdiagnosed that way; a read token is
  not needed.
- **Pushes do not upload new objects.** The standard
  [bootstrap](templates/cloud-sessions/README.md) points `core.hooksPath` at the
  Workshop mount's `Tools/hooks`, so git ignores `.git/hooks`, and a plain
  `git lfs install` stops with an error on Workshop's `post-checkout`. Without
  git-lfs's `pre-push` there, a pushed commit references objects the remote
  never received.

## The fix

With a custom network policy, the declaration's `allowedDomains` must admit
GitHub's LFS hosts. plunk-godot, jet-letter, and marble-lab declare
`github.com`, `lfs.github.com`, `github-cloud.githubusercontent.com`,
`github-cloud.s3.amazonaws.com`, and `objects.githubusercontent.com`.

The setup script installs `git-lfs`, which the platform image does not ship,
and registers its filters:

```bash
apt-get install -y git-lfs
git lfs install --system --skip-repo
```

At session start, the repository's `scripts/agent/cloud-env.sh`, which the
bootstrap chains under its ephemeral-session contract, calls the shared tool:

```bash
bash workshop/Tools/cloud-git-lfs.sh session --include='assets/**'
```

`session` runs three steps, each also available alone:

| Command | Effect |
|---|---|
| `credential-fallback` | Appends a repository-local helper for `https://github.com` that answers `username=git`, `password=placeholder` only after every earlier helper returned nothing. The proxy supplies the real authorization. Idempotent. |
| `pre-push-hook` | Installs git-lfs's `pre-push` alone into the effective hooks directory, wiring `core.hooksPath` first as the bootstrap would. Never overwrites a foreign `pre-push`. |
| `hydrate [--verify]` | Pulls, then asserts a positive census: at least one LFS file under the patterns and zero pointers. |

Omit `--include` to hydrate everything. Hydrate at session start only what
the repository's checks need; large archives that most sessions never open
are better pulled on demand with `hydrate --include=<path>/**`, after
`credential-fallback` has run. The caller gates on an ephemeral session: the
fallback belongs in a cloud checkout, not a local one. The script's header
documents its exit codes.

## Evidence

plunk-godot established the fallback and recorded the incidents and
verification rounds in its `docs/cloud-environment.md`. A cloud session there
hydrated 180 of 180 pointers and pushed a throwaway branch with `Uploading LFS
objects: 100% (1/1)`. A later session hit the missing-credentials failure
twice, once on pull and once on a push with no LFS content. With the fallback
installed, a session hydrated 250 files from 135 pointers and an ordinary push
succeeded. jet-letter and marble-lab adopted the same helper.
`tests/test-cloud-git-lfs.sh` covers the helper chain, the hook placement,
hydration, and an upload against a local remote; the proxy half can be
observed only in a cloud session.

To verify a repository's first session, read the `cloud-git-lfs:` lines for
`0 pointers`, then push a throwaway branch carrying one new LFS file and read
`Uploading LFS objects` in the push's own output. Cloud sessions cannot delete
remote branches, so remove it from a local checkout afterwards.

## See also

- [Claude Code Web environment declarations](claude-code-web.md) — setup scripts
  and the declaration's network allowlist, which must admit GitHub's LFS hosts
- [Cloud-session bootstrap kit](templates/cloud-sessions/README.md) — the
  session-start chain that runs `scripts/agent/cloud-env.sh`
