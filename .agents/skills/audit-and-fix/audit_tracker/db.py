"""SQLite connection and schema helpers for the audit tracker.

The database is a pure derived cache, so it lives **outside the committed
tree**: under ``$(git rev-parse --absolute-git-dir)/audit-tracker/``. The
absolute git dir is worktree- and submodule-safe (``.git`` is a file in
both, and a literal ``<repo>/.git`` path would break there), and nothing
under the git dir is ever committed, so no consumer needs a gitignore entry.
"""

import sqlite3
from pathlib import Path

from . import git_utils

SCHEMA_PATH = Path(__file__).resolve().parent / "schema.sql"
CACHE_DIRNAME = "audit-tracker"
CACHE_DB_FILENAME = "cache.sqlite3"


def cache_dir(git_dir: Path | None = None) -> Path:
    """The tracker's private directory inside the repo's git dir."""
    base = git_dir if git_dir is not None else git_utils.absolute_git_dir()
    return base / CACHE_DIRNAME


def default_db_path(git_dir: Path | None = None) -> Path:
    """The SQLite cache path: ``<git-dir>/audit-tracker/cache.sqlite3``."""
    return cache_dir(git_dir) / CACHE_DB_FILENAME


def connect(db_path: Path | None = None) -> sqlite3.Connection:
    """Open a SQLite connection with foreign keys enabled and row access by name."""
    resolved = db_path if db_path is not None else default_db_path()
    resolved.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(resolved)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_schema(conn: sqlite3.Connection) -> None:
    """Create tables and indexes if they don't exist."""
    conn.executescript(SCHEMA_PATH.read_text(encoding="utf-8"))
    conn.commit()
