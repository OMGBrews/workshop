# Git LFS in cloud sessions

How a repository that tracks files with Git LFS makes them readable and
pushable in cloud sessions. The Claude proxy fallback and Codex direct hydration
paths are distinct. Read this when a cloud checkout
holds LFS pointers, when `git lfs` reports missing credentials there, or when
adding LFS to a repository with a [Web declaration](claude-code-web.md).

## What goes wrong without it

Independent failures observed in Claude Code on the Web, each silent or misleading:

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
- **A pull can leave the index stale and still exit 0.** When `git lfs pull`
  cannot update the index, for example because another process holds
  `index.lock`, it prints `Error updating the Git index` and exits 0. The files
  are hydrated, but the index keeps each placeholder's size, and git treats a
  size change as a modification without comparing content. `git status` then
  lists every such file as modified, while `git diff` and
  `git update-index --refresh` find nothing to fix. plunk-godot hit this in a
  session that ran every hook twice: 149 of 322 files showed as modified.

## Claude proxy setup

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
| `hydrate [--verify]` | Pulls, then asserts a positive census: at least one LFS file under the patterns, zero pointers, and an index that agrees with the hydrated files. A pull rewrites stale entries from the index with `git checkout`, which leaves real edits alone; `--verify` reports them without changing anything. Only a file whose content is a placeholder counts as one, so uncommitted edits never fail the census. |

Omit `--include` to hydrate everything. Hydrate at session start only what
the repository's checks need; large archives that most sessions never open
are better pulled on demand with `hydrate --include=<path>/**`, after
`credential-fallback` has run. The caller gates on an ephemeral session: the
fallback belongs only in the demonstrated Claude proxy checkout, not every cloud
checkout. Cloud location or ephemeral permission alone does not establish that
another platform uses that proxy contract. The script's header
documents its exit codes.

## Codex manual hydration

The Codex manual route reuses `hydrate` independently of Claude authentication:

```bash
bash workshop/Tools/cloud-git-lfs.sh hydrate
```

Use the platform's existing HTTPS Git authentication. Provision `git-lfs` and the
network access needed by the repository before the task; keep credentials in the
platform's secret configuration, never the declaration, Git, or command output.
Do not call `session` or `credential-fallback` for Codex. Explicit
`AGENT_SESSION_EPHEMERAL=false` at bootstrap also prevents an adopter's
Claude-oriented ephemeral-session hook from selecting that fallback. The
[session environment contract](session-environment.md#explicit-codex-cloud-contract)
separates this permission from cloud location.

The tool already separates authentication setup, pre-push setup and hydration;
Codex needs no copied hydration implementation. Require its positive census: at
least one file in the requested scope, zero pointers and current index. Run again
after a source refresh when necessary; an onboarding result does not establish
that a fresh task's files are hydrated. If authentication, network access or the
census fails, report required rendering checks as unavailable with the command
and cause. Do not install the Claude placeholder helper as a guessed repair and
do not skip or weaken checks that read private assets.

Successful hydration proves reads, not upload of newly created LFS objects. A
successful ordinary Git push with no new LFS object does not prove LFS upload
either. A workflow that needs new uploads must separately verify the effective
pre-push hook and actual upload under its own platform authentication. The
`pre-push-hook` command is independently available, but its configuration alone
is not upload evidence. Record these distinctions in the consumer's
[Codex declaration](codex-cloud.md).

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
