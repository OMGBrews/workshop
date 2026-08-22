"""Thin wrappers around the ``git`` CLI used by the audit tracker.

All functions run from the repository root so that paths are repo-relative.
The root is wherever the **process** was started, not where this module
physically lives: the package ships inside a consumer's pinned ``workshop/``
mount, so ``__file__`` anchors at the mount while the audited tree is the
consumer repo around it. Every entry point documents running from the
consumer root, and ``git rev-parse`` resolves from there — through worktrees
and submodules too, where ``.git`` is a file rather than a directory.
"""

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


def _run(args: list[str], cwd: Path | None = None) -> str:
    cwd = cwd or repo_root()
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


def ls_files() -> list[str]:
    """Return every tracked file, repo-relative with POSIX separators."""
    out = _run(["ls-files"])
    return [line for line in out.splitlines() if line]


GITLINK_MODE = "160000"
SYMLINK_MODE = "120000"

# Git's SHA-1 of the zero-length blob — the same constant in every SHA-1
# repository, and this one is SHA-1 (`git rev-parse --show-object-format`).
# A SHA-256 repository would use a different constant, but defending against
# a format this repo does not use would be dead code.
EMPTY_BLOB_SHA = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"


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
    return {path for _mode, object_sha, path in _ls_files_staged() if object_sha == EMPTY_BLOB_SHA}


def submodule_owned_paths() -> set[str]:
    """Return tracked paths this repo cannot keep a change to.

    Two kinds qualify. A **gitlink** (mode ``160000``) is a submodule root
    itself. A **symlink** (mode ``120000``) qualifies when its target lands
    inside one of those roots — which is how the fleet-shared skills, and a
    handful of files that look local, reach this repo.

    Resolution is deliberately **full** (:meth:`Path.resolve`), not lexical.
    ``docs/work/tasks/_TEMPLATE.md`` points at
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
