"""Thin wrappers around the ``git`` CLI used by the audit tracker.

All functions run from the repository root so that paths are repo-relative.
The root is wherever the **process** was started, not where this module
physically lives: the package ships inside a consumer's pinned ``workshop/``
mount, so ``__file__`` anchors at the mount while the audited tree is the
consumer repo around it. Every entry point documents running from the
consumer root, and ``git rev-parse`` resolves from there — through worktrees
and submodules too, where ``.git`` is a file rather than a directory.
"""

import hashlib
import subprocess
from pathlib import Path

_cached_repo_root: Path | None = None


class NotARepositoryError(Exception):
    """Raised when the process runs outside any git repository."""


def repo_root() -> Path:
    """Repository root of the caller's working directory.

    Resolved once per process and cached: the tracker is CLI-shaped, so the
    first caller's CWD is the right answer for the whole run. Tests that
    move the working tree call :func:`reset_repo_root_cache`.
    """
    global _cached_repo_root
    if _cached_repo_root is None:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise NotARepositoryError(
                "audit_tracker must run inside the consumer's git repository "
                f"(from its root): {result.stderr.strip()}"
            )
        _cached_repo_root = Path(result.stdout.strip())
    return _cached_repo_root


def reset_repo_root_cache() -> None:
    """Forget the cached root so the next call re-resolves from CWD."""
    global _cached_repo_root
    _cached_repo_root = None


def absolute_git_dir() -> Path:
    """The repository's absolute git dir, worktree/submodule-safe.

    ``--absolute-git-dir`` (not a literal ``<root>/.git``): in a linked
    worktree or a submodule ``.git`` is a *file*, and derived caches belong
    beside the real store either way.
    """
    result = subprocess.run(
        ["git", "rev-parse", "--absolute-git-dir"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise NotARepositoryError(
            f"cannot resolve the git dir: {result.stderr.strip()}"
        )
    return Path(result.stdout.strip())


def _run(
    args: list[str], cwd: Path | None = None, *, input_text: str | None = None
) -> str:
    cwd = cwd or repo_root()
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        input=input_text,
        check=True,
    )
    return result.stdout


def ls_files() -> list[str]:
    """Return every tracked file, repo-relative with POSIX separators."""
    out = _run(["ls-files", "-z"])
    return [path for path in out.split("\0") if path]


GITLINK_MODE = "160000"
SYMLINK_MODE = "120000"

def empty_blob_sha() -> str:
    """Return Git's empty-blob object id in this repository's object format."""
    return _run(["hash-object", "--stdin"], input_text="").strip()


def _ls_files_staged() -> list[tuple[str, str, str]]:
    """Return ``(mode, object_sha, path)`` for every index entry.

    ``--stage`` exposes both fields. The mode is the only thing
    distinguishing a submodule root or a symlink from an ordinary blob; the
    object SHA is what makes emptiness readable without stat-ing the tree.
    ``-z`` is required rather than cosmetic: without it git quotes paths
    containing unusual bytes, and a quoted path would silently fail to match
    the same path as reported by :func:`ls_files`.
    """
    out = _run(["ls-files", "--stage", "-z"])
    entries: list[tuple[str, str, str]] = []
    for record in out.split("\0"):
        if not record:
            continue
        meta, _, path = record.partition("\t")
        # Each record is "<mode> <object> <stage>\t<path>"; stage is unused.
        mode, object_sha, _stage = meta.split(" ", 2)
        entries.append((mode, object_sha, path))
    return entries


def empty_blob_paths() -> set[str]:
    """Return tracked paths whose indexed content is empty.

    Read out of the index rather than off the filesystem: it reports what
    git tracks rather than what happens to be on disk, and costs one
    subprocess for the whole tree instead of a stat per file. A gitlink's
    object is a commit and a symlink's blob holds its (non-empty) target, so
    comparing the SHA alone cannot misclassify either kind.
    """
    empty_sha = empty_blob_sha()
    return {
        path
        for _mode, object_sha, path in _ls_files_staged()
        if object_sha == empty_sha
    }


def symlink_paths() -> set[str]:
    """Return every tracked symlink path from the index.

    Symlinks are not safe audit subjects even when their targets stay inside
    the repository: Git history and audit records follow the link blob, not
    changes to the target content an auditor would actually read.
    """
    return {
        path for mode, _object_sha, path in _ls_files_staged()
        if mode == SYMLINK_MODE
    }


def index_fingerprint() -> str:
    """Return a digest of the current Git index entries.

    Unlike HEAD, this changes for staged adds, deletes, renames, and content
    changes. The tracker uses it to invalidate its derived path/applicability
    cache before a commit is made. Reading ``ls-files --stage`` avoids
    ``write-tree``'s object-store mutation and works even with an unmerged
    index.
    """
    result = subprocess.run(
        ["git", "ls-files", "--stage", "-z"],
        cwd=repo_root(),
        capture_output=True,
        check=True,
    )
    return hashlib.sha256(result.stdout).hexdigest()


def submodule_owned_paths() -> set[str]:
    """Return tracked paths this repo cannot keep a change to.

    Two kinds qualify. A **gitlink** (mode ``160000``) is a submodule root
    itself. A **symlink** (mode ``120000``) qualifies when its target lands
    inside one of those roots — which is how the fleet-shared skills, and a
    handful of files that look local, reach this repo.

    Resolution is deliberately **full** (:meth:`Path.resolve`), not lexical.
    A symlink's link text can look local while its target lives in a
    submodule: ``handbook/briefs/_TEMPLATE.md`` points at
    ``.claude/skills/task-create/_TEMPLATE.md``, whose *first* component is
    itself a symlink into the submodule. Normalizing the link text would see
    a local-looking path and let the file through, which is the failure this
    function exists to prevent.

    Returns an empty set in a repo with no submodules.
    """
    entries = _ls_files_staged()
    roots = {path for mode, _object_sha, path in entries if mode == GITLINK_MODE}
    if not roots:
        return set()

    resolved_roots = [(repo_root() / root).resolve() for root in roots]
    owned = set(roots)
    for mode, _object_sha, path in entries:
        if mode != SYMLINK_MODE:
            continue
        target = (repo_root() / path).resolve()
        if any(target == root or root in target.parents for root in resolved_roots):
            owned.add(path)
    return owned


def head_sha() -> str:
    """Return the current HEAD commit SHA."""
    return _run(["rev-parse", "HEAD"]).strip()


class UnknownCommitError(Exception):
    """Raised when a SHA passed to :func:`commits_since` is not in the repo.

    Caused by rebases, force-pushes, or garbage collection dropping the
    original commit. Callers should treat the audit as stale rather than
    fresh, since staleness cannot be determined.
    """


def commits_since(since_sha: str, path: str) -> int:
    """Count commits touching ``path`` between ``since_sha`` and HEAD.

    Works for both files and directories (git natively recurses into a
    directory when it is passed as a pathspec). Returns 0 when the SHA is
    known but nothing has changed. Raises :class:`UnknownCommitError` when
    ``since_sha`` is not a commit object in this repo.
    """
    try:
        _run(["cat-file", "-e", f"{since_sha}^{{commit}}"])
    except subprocess.CalledProcessError as exc:
        raise UnknownCommitError(f"{since_sha!r} is not a known commit in this repo") from exc
    out = _run(["rev-list", "--count", f"{since_sha}..HEAD", "--", path])
    return int(out.strip() or "0")


def commits_since_many(since_sha: str, paths: list[str]) -> dict[str, int]:
    """Count touching commits for many file/directory paths in one Git walk.

    The former one-path-at-a-time implementation spawned two Git processes per
    audited path. ``git log --name-only`` walks the range once; this function
    then applies the same pathspec semantics locally (exact file or any child
    of a directory). A commit touching several children still counts once for
    the directory, matching ``rev-list --count ... -- <directory>``.
    """
    try:
        return commits_since_many_by_sha({since_sha: paths})[since_sha]
    except KeyError as exc:
        raise UnknownCommitError(
            f"{since_sha!r} is not a reachable commit in this repo"
        ) from exc


def commits_since_many_by_sha(
    requests: dict[str, list[str]],
) -> dict[str, dict[str, int]]:
    """Count path-touching commits for every requested audit SHA in one walk.

    A production records file can contain hundreds of distinct audit commits.
    Spawning one ``git log`` per SHA remains quadratic in process overhead, so
    this reads the reachable commit graph and changed names once. Parent links
    let the Python side reproduce ``SHA..HEAD`` correctly across merges by
    excluding the full ancestor set of each audit commit.

    SHAs not reachable from HEAD are omitted. Callers classify those records
    as stale because the prior audit can no longer be proved current.
    """
    if not requests:
        return {}
    raw = _run(
        [
            "log",
            "--format=%x1e%H%x00%P%x00",
            "--name-only",
            "--no-renames",
            "-z",
            "HEAD",
            "--",
        ]
    )
    graph: dict[str, tuple[tuple[str, ...], set[str]]] = {}
    for commit_record in raw.split("\x1e"):
        if not commit_record:
            continue
        fields = commit_record.split("\0")
        sha = fields[0].strip()
        if not sha:
            continue
        parents = tuple(fields[1].split()) if len(fields) > 1 else ()
        changed = {
            value.lstrip("\n")
            for value in fields[2:]
            if value.lstrip("\n")
        }
        graph[sha] = (parents, changed)

    all_commits = set(graph)
    result: dict[str, dict[str, int]] = {}
    for audit_sha, paths in requests.items():
        if audit_sha not in graph:
            continue
        ancestors: set[str] = set()
        pending = [audit_sha]
        while pending:
            sha = pending.pop()
            if sha in ancestors:
                continue
            ancestors.add(sha)
            node = graph.get(sha)
            if node is not None:
                pending.extend(node[0])
        counts = dict.fromkeys(paths, 0)
        for commit_sha in all_commits - ancestors:
            changed = graph[commit_sha][1]
            if not changed:
                continue
            for path in paths:
                prefix = path + "/"
                if path in changed or any(name.startswith(prefix) for name in changed):
                    counts[path] += 1
        result[audit_sha] = counts
    return result
