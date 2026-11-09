# Repository views

Use `Tools/repository_view.py` to give a repository-wide check one captured set
of paths and bytes, plus any explicitly named target repositories, which are
listed and consulted live (see
[Independent target repositories](#independent-target-repositories)). The
standard-library Python API and command-line adapter share discovery, file
types, symlink resolution, and submodule handling; a consumer supplies its own
policy and parser.

## Modes and boundaries

`working-tree` captures visible tracked files and non-ignored untracked files,
using their current contents and omitting tracked paths already deleted when
capture starts. Conflicted index entries still supply their visible working
contents in this mode; index mode rejects those conflicts. Ignored untracked files are absent, including when checking a
link target. Populated submodules contribute their visible contents, including
local edits and non-ignored untracked files. A missing checkout is represented
as an unavailable mount, not an empty directory.

`index` captures stage-zero modes and object bytes from the proposed index.
Unstaged edits, ignored files, and untracked paths cannot change it. Each
gitlink resolves recursively to its recorded commit, using local child object
storage even when its checkout differs or is deinitialized. Required objects
must exist locally; the provider never fetches or substitutes another revision.
Unresolved index entries and missing required objects are evaluation errors.

Each entry identifies its owning repository by its mount path (`""` for the
parent), its `tracked` or `untracked` origin, and its kind: `file`, `symlink`,
`directory`, or `unavailable`. Directories are inferred from included entries,
so an empty untracked directory is absent. A visible directory replacing a
tracked file is retained, including when empty; a file or symlink replacing a
tracked directory hides that directory’s former descendants. Mount directories retain gitlink
mode `160000`. Sources can be restricted to parent ownership while targets
remain accessible in child repositories.

Construction requires quiescent input. The provider checks the index, untracked
inventory, and encountered file metadata for changes during capture, but this
is not a filesystem-wide atomic transaction. A disappearance after a file is
selected for reading, unsupported file type, or unreadable input errors instead
of silently shrinking the view. After construction the inspected repository's
captured bytes remain stable for the context's lifetime; target repositories
keep the narrower guarantee described under their own heading. The provider
copies the bytes it reads; it never writes the caller's files or index and does
not use hardlinks back to them.

## Python consumers

Add the pinned Workshop `Tools` directory to the consumer's import path, keeping
code loaded from that original location rather than the data snapshot:

```python
from repository_view import RepositoryView, ViewError

with RepositoryView(repo_root, mode="index") as view:
    for source in view.paths(owner="", suffix=".md"):
        if view.entries[source]["kind"] == "symlink":
            continue
        contents = view.read_bytes(source)
        # Apply this consumer's policy to the captured bytes.
```

`RepositoryView(repo, mode="working-tree")` is a context manager. Its public
attributes are `root` (a temporary `Path`), `manifest` (the JSON manifest path),
`entries` (path-to-metadata mapping), `unavailable` (mount paths), and `mode`.
`ManifestView.load(manifest)` attaches to an existing view without rediscovery;
its lifetime is still controlled by the original context or CLI runner.

- `paths(owner=None, origin=None, suffix="")` yields non-directory source
  paths. Use `owner=""` for parent-owned sources and `origin="tracked"` when
  the consumer requires tracked-only discovery.
- `resolve(path)` returns a logical repository-relative path after resolving
  captured symlink metadata. Missing ordinary paths remain missing paths.
- `exists(path)` and `is_dir(path)` use only captured entries, or, beneath a
  target repository, listed names confirmed on first use.
- `path(path)` returns a confined materialized `Path`; `read_bytes(path)` reads
  its captured contents and wraps read failures in `ViewError`. Beneath a
  target repository the file is read and materialized on first use.
- `unavailable_mount(path)` returns an unavailable mount containing the lexical
  path, or `None`. Resolving a symlink into such a mount raises
  `UnavailableViewError`, a `ViewError` subclass carrying a `mount` attribute.
- `normalize_link_path(source, target)` lexically joins a relative target to
  its source directory without splitting or trimming names. It leaves leading
  `..` segments visible so consumers can apply their repository-escape policy.

Paths use Python filesystem strings, preserving undecodable bytes with
`surrogateescape`. Spaces, embedded newlines, and trailing newlines are data.
Consumers must not split paths on whitespace or trim them.

Symlinks are metadata only: the materialized root contains no host symlinks.
Always use the logical methods to resolve a potential symlink target before
reading. Relative symlinks resolve inside the logical namespace; absolute
symlinks, escaping symlinks, and cycles raise `ViewError`. They cannot read live
files outside the view's paths, and a target repository's symlink is read
without following it when first consulted. A consumer can still enumerate and
report a skipped symlink source without resolving it.

## Shell consumers

Run an external command for the lifetime of either view:

```bash
python3 workshop/Tools/repository_view.py run --mode working-tree --repo . -- \
  bash /absolute/path/to/check-captured-docs.sh
```

The command retains the caller's working directory and receives
`REPOSITORY_VIEW_ROOT` and `REPOSITORY_VIEW_MANIFEST`. Keep the consumer and
provider executable paths outside the snapshot. The manifest has schema
`version: 1`, `root`, `mode`, `entries`, and `unavailable`; its JSON strings
preserve filesystem names. Use the provider's NUL-delimited adapter instead of
reconstructing source discovery:

```bash
python3 "$workshop_tools/repository_view.py" list \
  --manifest "$REPOSITORY_VIEW_MANIFEST" --owner '' --suffix .md > "$source_list"
while IFS= read -r -d '' source; do
  printf 'checking %s\n' "$source"
done < "$source_list"
```

`list` also accepts `--origin tracked` or `--origin untracked`. `resolve
--manifest MANIFEST PATH` emits one canonical logical path followed by NUL.
Use `read -r -d ''`, not command substitution, to retain trailing newlines;
check the adapter's exit status before using its output. Resolve targets before
reading beneath `REPOSITORY_VIEW_ROOT`, and inspect source metadata when the
consumer needs to skip symlinks rather than follow them.

The runner propagates the consumer's exit status and cleans up on success,
failure, and handled termination signals. Signals are forwarded to the direct
consumer; consumers own termination of their descendants. Uncatchable process
termination such as `SIGKILL` cannot guarantee cleanup. Capture failures and
adapter errors exit 2 with a diagnostic; no policy verdict can be inferred
from an unavailable view.

## Markdown checker

[`check-markdown-links.sh`](../Tools/check-markdown-links.sh) uses the
working-tree view for source enumeration, skip configuration, target types,
and heading anchors. It scans parent-owned `.md` sources and allows child
repository documents as targets. Links into unavailable working-tree mounts
are named skips. Broken links and stale skip entries exit 1; capture, parsing,
and unsupported resolution failures exit 2, taking precedence over findings.
The checker retains its own link grammar and URI/fragment policies; those are
not part of the reusable provider.

The checker's grammar remains shared with
[`rewrite-moved-markdown-links.sh`](../Tools/rewrite-moved-markdown-links.sh):
single-line inline links, images, and reference definitions accept
angle-bracketed destinations or whitespace-free destinations without
parentheses, with optional titles. Fenced and inline code are excluded;
footnote definitions are not reference links. Targets are percent-decoded for
lookup, preserving an encoded NUL. URI links are named skips; absolute paths
are excluded; repository-escaping relative paths are named skips. Same-file and
cross-file Markdown fragments are checked against rendered heading IDs and
explicit HTML anchors. Non-Markdown fragments are named skips after existence
is checked. Symlink sources are skipped by name.

A root `.markdown-links-skip` file can exclude sources: one repository-relative
path per line, with a trailing `/` for a directory prefix. Blank lines and `#`
comments are ignored; use comments to explain exclusions. Wildcards, absolute
paths, and `..` segments are errors (exit 2). Every skipped source is named, and
entries matching no visible parent-owned Markdown source fail (exit 1). This
line-based configuration cannot name a single newline-bearing source directly;
a directory prefix can still exclude it. The skip file itself is read through
the captured view, including confined symlink resolution.

## Independent target repositories

A workspace index may deliberately ignore independent clones. A working-tree
caller can opt them into the captured target namespace with
`RepositoryView(root, target_repositories=("workshop", "studio/project"))`.
The Markdown checker exposes the same contract through repeatable
`--target-repository RELATIVE_PATH` arguments. Callers own that explicit registry;
there is no automatic discovery of ignored directories.

Each target must be an existing independent repository root below the inspected
root, without symlink ancestors or overlaps with listed paths. A missing root
is an evaluation error. Index views refuse this option because these clones are
not part of the parent's index.

A target contributes names, not copies. Construction lists its tracked and
non-ignored untracked paths from Git once, with its own repository ownership,
and recurses into populated submodules; an unpopulated submodule is an
unavailable mount as in the parent. Nothing beneath a target is opened, typed,
or copied at construction. The target supplies link targets and anchors but
never parent Markdown sources, and its own ignored files remain invisible
because only listed paths and their ancestors are ever consulted.

A listed path is checked on the live tree the first time a lookup reaches it,
without following symlinks, and the answer is kept for the context's lifetime.
The working-tree type rules above apply: a directory inferred from listed paths
exists only while one of them is visible, a listed path that is now a directory
exists even when empty, and a file or symlink replacing a tracked directory
hides its former descendants. A target file is read on first use with the same
before-and-after metadata test as capture, so a file changing during its own
read is an evaluation error, and later reads return those same bytes. Nothing
else about a changing target is detected: a path is answered as it stood when
first consulted, and an unsupported file type is an error only when consulted.

The manifest records a target's entries as names only, with kind
`unconfirmed`; `ManifestView` cannot confirm them, so its `paths()` yields the
listed names and omits inferred directories.
