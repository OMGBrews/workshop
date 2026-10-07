"""Control and subject repositories.

The **control** repository is the one the process runs in. It owns the audit
config, the committed records, and the derived cache, exactly as it always
has; inside the tracker it is named ``self``. A **subject** is a separately
versioned Git repository mounted beneath the control root — a submodule or a
plain nested clone — that the config declares by name::

    [repositories.library]
    path = "library"

Target rules opt into a subject with ``repository = "library"``. Candidate
paths are then relative to the subject's root, its history decides staleness,
and its records live in the control repository under
``docs/work/audits/records/<name>/``. Nothing is installed in the subject.

A declaration is only trusted once its path resolves *exactly* to a Git
worktree root. That single comparison is what makes every broken mount fail
loudly: an uninitialized submodule is an empty directory whose
``--show-toplevel`` is the control root, a plain directory reports the same,
and a moved repository leaves either nothing or the wrong toplevel behind.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from . import git_utils
from .config import SELF_REPOSITORY, Config, Repository
from .git_utils import SubjectRepositoryError


@dataclass(frozen=True)
class RepositoryContext:
    """A repository the tracker may read: its name and worktree root.

    ``declared_path`` is the control-relative path from the config, or
    ``None`` for the control repository itself.
    """

    name: str
    root: Path
    declared_path: str | None = None

    @property
    def is_self(self) -> bool:
        return self.name == SELF_REPOSITORY


def control() -> RepositoryContext:
    """The control repository: the process's own Git worktree."""
    return RepositoryContext(name=SELF_REPOSITORY, root=git_utils.repo_root())


def _check_subject_root(declaration: Repository, control_root: Path) -> Path:
    """Return the subject's worktree root or raise ``SubjectRepositoryError``."""
    where = f"repository {declaration.name!r} (path {declaration.path!r})"
    current = control_root
    for part in declaration.path.split("/"):
        current = current / part
        # Lexical walk, one component at a time: a symlink anywhere on the
        # way could point outside the control tree or at another repository,
        # and resolving through it would hide that.
        if current.is_symlink():
            raise SubjectRepositoryError(
                f"{where}: {current.relative_to(control_root).as_posix()!r} is a "
                "symlink; declared repository paths must be real directories "
                "beneath the control root"
            )
        if not current.exists():
            raise SubjectRepositoryError(
                f"{where} is missing: {current} does not exist. Initialize or "
                "clone it there (for a submodule: git submodule update --init "
                f"{declaration.path}), or remove the declaration."
            )
    if not current.is_dir():
        raise SubjectRepositoryError(f"{where}: {current} is not a directory")
    toplevel = git_utils.toplevel(current)
    if toplevel is None:
        raise SubjectRepositoryError(f"{where}: {current} is not inside a Git repository")
    if toplevel.resolve() != current:
        raise SubjectRepositoryError(
            f"{where} is not a Git worktree root: Git resolves {current} to the "
            f"repository at {toplevel}. The subject is uninitialized, was moved, "
            "or the path names a plain directory."
        )
    if git_utils.resolve_commit(current, "HEAD") is None:
        raise SubjectRepositoryError(f"{where} has no commits yet")
    return current


def resolve(config: Config, name: str) -> RepositoryContext:
    """Resolve one repository by name, validating a subject's root."""
    if name == SELF_REPOSITORY:
        return control()
    declaration = config.repositories.get(name)
    if declaration is None:
        known = ", ".join(config.repository_names())
        raise SubjectRepositoryError(
            f"unknown repository {name!r}; configured repositories: {known}"
        )
    control_root = git_utils.repo_root().resolve()
    root = _check_subject_root(declaration, control_root)
    return RepositoryContext(name=name, root=root, declared_path=declaration.path)


def resolve_all(config: Config, names: list[str] | None = None) -> list[RepositoryContext]:
    """Resolve ``names`` (default: every configured repository), in order.

    The first broken subject raises; nothing partial is returned, so a
    command reading every repository can never report a short queue.
    """
    return [resolve(config, name) for name in (names or config.repository_names())]


def declared_subject_for(config: Config, control_path: str) -> Repository | None:
    """The declared subject whose tree contains a control-relative path."""
    for declaration in config.repositories.values():
        if control_path == declaration.path or control_path.startswith(
            declaration.path + "/"
        ):
            return declaration
    return None


__all__ = [
    "RepositoryContext",
    "SubjectRepositoryError",
    "control",
    "declared_subject_for",
    "resolve",
    "resolve_all",
]
