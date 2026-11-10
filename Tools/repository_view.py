#!/usr/bin/env python3
"""Captured Git repository views for checks; see docs/repository-views.md."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import errno
import json
import os
from pathlib import Path
import posixpath
import signal
import stat
import subprocess
import sys
import tempfile


class ViewError(RuntimeError):
    """The requested repository view or logical path cannot be evaluated."""


class UnavailableViewError(ViewError):
    """A logical path enters a working-tree mount without a checkout."""

    def __init__(self, mount: str):
        self.mount = mount
        super().__init__(f"unavailable submodule: {mount!r}")


def _git(repo: Path, *args: str, data: bytes | None = None, store: bool = False) -> bytes:
    command = (["git", "--git-dir", str(repo), "--work-tree", str(repo)] if store else ["git", "-C", str(repo)])
    result = subprocess.run([*command, *args], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ViewError(f"git {' '.join(args[:2])}: {os.fsdecode(result.stderr).strip()}")
    return result.stdout


# A target repository's two listings. They are read-only, so the view runs them
# concurrently across repositories: on slow filesystems they dominate capture.
_STAGED = ("ls-files", "--stage", "-z")
_OTHERS = ("ls-files", "--others", "--exclude-standard", "-z")
_LISTING_WORKERS = min(16, os.cpu_count() or 4)


def _name(value: bytes) -> str:
    return os.fsdecode(value)


def normalize_link_path(source: str, target: str) -> str:
    """Lexically join a relative link without stripping or splitting byte names."""
    return posixpath.normpath((posixpath.dirname(source) or ".") + "/" + target) if target else source


def _stamp(value: os.stat_result):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns)


def _safe(path: str) -> str:
    if path.startswith("/") or "\0" in path:
        raise ViewError(f"unsupported repository path: {path!r}")
    normalized = posixpath.normpath(path)
    if normalized == ".." or normalized.startswith("../"):
        raise ViewError(f"path escapes repository: {path!r}")
    return "" if normalized == "." else normalized


UNCONFIRMED = "unconfirmed"


class ManifestView:
    """Read-only logical operations over an already captured view."""

    @classmethod
    def load(cls, manifest: str | Path) -> ManifestView:
        try:
            data = json.loads(Path(manifest).read_text())
            if data["version"] != 1:
                raise ViewError("unsupported repository-view manifest version")
            view = cls()
            view.root = Path(data["root"])
            view.mode = data["mode"]
            view.entries = data["entries"]
            view.unavailable = data["unavailable"]
            return view
        except (OSError, ValueError, KeyError) as exc:
            raise ViewError(f"cannot read repository-view manifest: {exc}") from exc

    def _entry(self, path: str):
        """Return one entry's metadata; live views confirm target entries here."""
        return self.entries.get(path)

    def paths(self, *, owner: str | None = None,
              origin: str | None = None, suffix: str = ""):
        """Yield non-directory entries, preserving names (including newlines).

        A target repository's unconfirmed entries are names only: inferred
        directories are omitted and listed names are yielded unconfirmed.
        """
        for path, entry in sorted(self.entries.items()):
            if entry["kind"] in ("directory", "unavailable"):
                continue
            if entry["kind"] == UNCONFIRMED and entry.get("inferred"):
                continue
            if owner is not None and entry["owner"] != owner:
                continue
            if origin is not None and entry["origin"] != origin:
                continue
            if path.endswith(suffix):
                yield path

    def unavailable_mount(self, path: str) -> str | None:
        path = _safe(path)
        return next((mount for mount in self.unavailable
                     if path == mount or path.startswith(mount + "/")), None)

    def resolve(self, path: str) -> str:
        """Resolve symlinks in the captured namespace, never the host filesystem."""
        path = _safe(path)
        for _ in range(41):
            mount = self.unavailable_mount(path)
            if mount is not None:
                raise UnavailableViewError(mount)
            parts = path.split("/") if path else []
            for index in range(len(parts)):
                prefix = "/".join(parts[:index + 1])
                entry = self._entry(prefix)
                if entry and entry["kind"] == "symlink":
                    target = entry["target"]
                    if target.startswith("/"):
                        raise ViewError(f"unsupported absolute symlink: {prefix!r}")
                    path = _safe(posixpath.join(posixpath.dirname(prefix), target,
                                               *parts[index + 1:]))
                    break
                if entry and entry["kind"] == "file" and index < len(parts) - 1:
                    # A file cannot supply descendants even if a later '..'
                    # would happen to erase it; normalized paths are lexical.
                    return path
            else:
                return path
        raise ViewError(f"symlink cycle or excessive depth: {path!r}")

    def exists(self, path: str) -> bool:
        return self._entry(self.resolve(path)) is not None

    def is_dir(self, path: str) -> bool:
        entry = self._entry(self.resolve(path))
        return entry is not None and entry["kind"] == "directory"

    def path(self, path: str) -> Path:
        """Return a confined materialized path; missing paths remain missing."""
        return self.root / self.resolve(path)

    def read_bytes(self, path: str) -> bytes:
        try:
            return self.path(path).read_bytes()
        except OSError as exc:
            raise ViewError(f"cannot read {path!r}: {exc.strerror}") from exc


class RepositoryView(ManifestView):
    """Context manager capturing working-tree or exact-index repository bytes."""

    def __init__(self, repo: str | Path, mode: str = "working-tree", *,
                 target_repositories: tuple[str, ...] = ()):
        if mode not in ("working-tree", "index"):
            raise ViewError(f"unknown repository-view mode: {mode}")
        if target_repositories and mode != "working-tree":
            raise ViewError("target repositories require a working-tree view")
        self.target_repositories = target_repositories
        self.repo = Path(repo).resolve()
        self.mode = mode
        self.entries = {"": {"kind": "directory", "owner": "", "origin": "tracked"}}
        self.unavailable = []
        self._temp = None
        self._active = set()
        # Target repositories contribute names, confirmed on first use.
        self._children = {}
        self._materialized = set()
        self._prefetched = {}

    def __enter__(self) -> RepositoryView:
        try:
            top = _name(_git(self.repo, "rev-parse", "--show-toplevel")[:-1])
            if Path(top).resolve() != self.repo.resolve():
                raise ViewError("repository view requires the repository root")
            self._temp = tempfile.TemporaryDirectory(prefix="repository-view-")
            self.root = Path(self._temp.name) / "root"
            self.root.mkdir()
            self.manifest = Path(self._temp.name) / "manifest.json"
            self._capture(self.repo, "", None)
            # Listings start early, but each is used only after its target passes
            # the checks below, in order; an unused listing is simply dropped. A
            # target that already fails a check here is never listed, and each
            # listing first confirms its target is a repository root.
            self._prefetch([self.repo / mount for mount in map(self._mount_or_none, self.target_repositories)
                            if mount and mount not in self.entries and not self._symlinked(self.repo / mount)],
                           roots=True)
            for requested in self.target_repositories:
                mount = _safe(requested)
                if not mount or mount in self.entries:
                    raise ViewError(f"target repository overlaps captured paths: {requested!r}")
                checkout = self.repo / mount
                if self._symlinked(checkout):
                    raise ViewError(f"symlink target repository: {requested!r}")
                top = Path(_name(_git(checkout, "rev-parse", "--show-toplevel")[:-1]))
                if top.resolve() != checkout.resolve():
                    raise ViewError(f"target repository is not a repository root: {requested!r}")
                self._parents(mount, mount, "untracked")
                self.entries[mount] = {"kind": "directory", "owner": mount,
                                       "origin": "untracked", "target_repository": True}
                self._adopt(mount)
                (self.root / mount).mkdir()
                self._list_target(checkout, mount)
            self.manifest.write_text(json.dumps({"version": 1, "mode": self.mode,
                "root": str(self.root), "entries": self.entries,
                "unavailable": self.unavailable}, ensure_ascii=True))
            return self
        except (OSError, ValueError, ViewError) as exc:
            self.__exit__(None, None, None)
            if isinstance(exc, ViewError):
                raise
            raise ViewError(f"cannot establish repository view: {exc}") from exc

    def __exit__(self, *_):
        if self._temp is not None:
            self._temp.cleanup()
            self._temp = None

    def _parents(self, path: str, owner: str, origin: str):
        parent = posixpath.dirname(path)
        if parent and parent not in self.entries:
            self._parents(parent, owner, origin)
            self.entries[parent] = {"kind": "directory", "owner": owner, "origin": origin}
            self._adopt(parent)
            (self.root / parent).mkdir(exist_ok=True)

    # -- Target repositories: names listed from Git, confirmed on demand. --

    def _adopt(self, path: str):
        """Record a path as its parent's child, for descendant confirmation."""
        self._children.setdefault(posixpath.dirname(path), []).append(path)

    def _note(self, path: str, entry: dict):
        """Record a target entry and infer unconfirmed parents, touching no file."""
        parent = posixpath.dirname(path)
        if parent and parent not in self.entries:
            self._note(parent, {"kind": UNCONFIRMED, "owner": entry["owner"],
                                "origin": entry["origin"], "inferred": True})
        previous = self.entries.get(path)
        if previous is None:
            self._adopt(path)
            self.entries[path] = entry
        elif previous["kind"] == UNCONFIRMED and previous.get("inferred"):
            # A listed name outranks a directory inferred from its descendants.
            self.entries[path] = entry

    def _list_target(self, repo: Path, owner: str):
        identity = (str(repo.resolve()), None)
        if identity in self._active:
            raise ViewError("recursive repository cycle")
        self._active.add(identity)
        try:
            _, tracked = self._index(repo, allow_unmerged=True, raw=self._listing(repo, _STAGED))
            others = self._listing(repo, _OTHERS)
            names = [(_safe(name), mode) for name, mode, _ in tracked]
            # A nested repository that is not a submodule is listed as "B/";
            # _safe normalizes it so the overlap test still sees "B".
            names += [(_safe(_name(name)), "") for name in others.split(b"\0") if name]
            # Resolve populated submodules first so their listings run together. A
            # resolution error is raised when the loop reaches that submodule, so
            # errors keep their depth-first order.
            children = {}
            for name, mode in names:
                if name and mode == "160000":
                    try:
                        children[name] = self._child(repo, name, b"", working=True, store=False, oid="")
                    except ViewError as exc:
                        children[name] = exc
            self._prefetch([child[0] for child in children.values() if isinstance(child, tuple)])
            for name, mode in names:
                if not name:
                    raise ViewError(f"invalid Git path: {name!r}")
                logical = posixpath.join(owner, name)
                if mode != "160000":
                    self._note(logical, {"kind": UNCONFIRMED, "owner": owner,
                                         "origin": "untracked" if mode == "" else "tracked"})
                    continue
                child = children[name]
                if isinstance(child, ViewError):
                    raise child
                if child is None:
                    self._note(logical, {"kind": "unavailable", "owner": owner,
                                         "origin": "tracked", "mode": "160000"})
                    self.unavailable.append(logical)
                    continue
                self._note(logical, {"kind": "directory", "owner": logical,
                                     "origin": "tracked", "mode": "160000"})
                self._list_target(child[0], logical)
        finally:
            self._active.remove(identity)

    def _symlinked(self, checkout: Path) -> bool:
        for ancestor in (checkout, *checkout.parents):
            if ancestor == self.repo:
                return False
            if ancestor.is_symlink():
                return True
        return False

    @staticmethod
    def _mount_or_none(requested):
        try:
            return _safe(requested)
        except ViewError:
            return None

    def _prefetch(self, repos, *, roots: bool = False):
        """Run each repository's listings concurrently; a failure waits for its reader.

        With roots, a repository is listed only once Git confirms it is its own
        root, so no listing runs where the ordered checks would refuse to list.
        """
        def fetch(repo):
            if roots:
                try:
                    top = Path(_name(_git(repo, "rev-parse", "--show-toplevel")[:-1]))
                except ViewError:
                    return None
                if top.resolve() != repo.resolve():
                    return None
            listings = []
            for args in (_STAGED, _OTHERS):
                try:
                    listings.append(_git(repo, *args))
                except ViewError as exc:
                    listings.append(exc)
            return listings
        unique = list(dict.fromkeys(repos))
        if not unique:
            return
        with ThreadPoolExecutor(max_workers=min(_LISTING_WORKERS, len(unique))) as pool:
            for repo, listings in zip(unique, pool.map(fetch, unique)):
                if listings is not None:
                    for args, result in zip((_STAGED, _OTHERS), listings):
                        self._prefetched[(str(repo), args)] = result

    def _listing(self, repo: Path, args: tuple[str, ...]) -> bytes:
        result = self._prefetched.pop((str(repo), args), None)
        if result is None:
            return _git(repo, *args)
        if isinstance(result, ViewError):
            raise result
        return result

    def _probe(self, path: str):
        """lstat one live path below the root without following any symlink."""
        parts = path.split("/")
        directory = os.open(self.repo, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for component in parts[:-1]:
                try:
                    next_dir = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                       dir_fd=directory)
                except (FileNotFoundError, NotADirectoryError):
                    return None, None
                except OSError as exc:
                    if exc.errno == errno.ELOOP:
                        return None, None
                    raise
                os.close(directory)
                directory = next_dir
            try:
                found = os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)
            except (FileNotFoundError, NotADirectoryError):
                return None, None
            target = (os.readlink(parts[-1], dir_fd=directory)
                      if stat.S_ISLNK(found.st_mode) else None)
            return found, target
        finally:
            os.close(directory)

    def _entry(self, path: str):
        entry = self.entries.get(path)
        if entry is not None and entry["kind"] == UNCONFIRMED:
            self._confirm(path)
            entry = self.entries.get(path)
        return entry

    def _confirm(self, path: str):
        """Settle one unconfirmed target entry against the live tree, once.

        Only listed names and their ancestors are ever confirmed, so an
        unlisted (ignored) live file is never visible.
        """
        entry = self.entries[path]
        parent = posixpath.dirname(path)
        above = self._entry(parent) if parent else self.entries[""]
        if above is None or above["kind"] != "directory":
            # A missing parent, or a file or symlink that replaced a tracked
            # directory, hides every former descendant.
            del self.entries[path]
            return
        found, target = self._probe(path)
        if found is None:
            del self.entries[path]
            return
        if stat.S_ISLNK(found.st_mode):
            confirmed = {"kind": "symlink", "mode": "120000", "target": target}
        elif stat.S_ISREG(found.st_mode):
            confirmed = {"kind": "file", "mode": "100755" if found.st_mode & 0o111 else "100644"}
        elif stat.S_ISDIR(found.st_mode):
            confirmed = {"kind": "directory"}
        else:
            raise ViewError(f"unsupported working-tree entry type: {path!r}")
        inferred = entry.get("inferred")
        if inferred and confirmed["kind"] != "directory":
            # The replacing file or symlink is itself unlisted content.
            entry = dict(entry, origin="untracked")
        merged = {key: value for key, value in entry.items() if key != "inferred"}
        merged.update(confirmed)
        self.entries[path] = merged
        if confirmed["kind"] != "directory":
            return
        # A listed directory is present even when empty. A directory inferred
        # only from listed descendants is present only if one of them is.
        if inferred and not any(self._entry(child) is not None
                                for child in list(self._children.get(path, ()))):
            del self.entries[path]
            return
        (self.root / path).mkdir(parents=True, exist_ok=True)

    def paths(self, *, owner: str | None = None,
              origin: str | None = None, suffix: str = ""):
        for path in [path for path, entry in self.entries.items()
                     if entry["kind"] == UNCONFIRMED and (owner is None or entry["owner"] == owner)]:
            if path in self.entries:
                self._entry(path)
        yield from super().paths(owner=owner, origin=origin, suffix=suffix)

    def path(self, path: str) -> Path:
        """Return a confined materialized path; target files are read on first use."""
        resolved = self.resolve(path)
        entry = self._entry(resolved)
        if (entry is not None and entry["kind"] == "file"
                and resolved not in self._materialized and not (self.root / resolved).exists()):
            try:
                mode, data, _ = self._visible(self.repo / resolved)
            except OSError as exc:
                raise ViewError(f"cannot read {path!r}: {exc.strerror}") from exc
            if mode not in ("100644", "100755"):
                raise ViewError(f"entry changed during capture: {resolved!r}")
            destination = self.root / resolved
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            self._materialized.add(resolved)
        return self.root / resolved

    def _put(self, path: str, owner: str, origin: str, mode: str, data: bytes):
        path = _safe(path)
        if not path or path != posixpath.normpath(path):
            raise ViewError(f"invalid Git path: {path!r}")
        self._parents(path, owner, origin)
        kind = {"120000": "symlink", "040000": "directory"}.get(mode, "file")
        entry = {"kind": kind, "owner": owner, "origin": origin, "mode": mode}
        self.entries[path] = entry
        if kind == "symlink":
            entry["target"] = _name(data)
        elif kind == "directory":
            (self.root / path).mkdir(exist_ok=True)
        else:
            (self.root / path).write_bytes(data)
            (self.root / path).chmod(0o755 if mode == "100755" else 0o644)

    @staticmethod
    def _index(repo: Path, *, allow_unmerged: bool = False, raw: bytes | None = None):
        if raw is None:
            raw = _git(repo, *_STAGED)
        entries = []
        for record in raw.split(b"\0"):
            if not record:
                continue
            header, name = record.split(b"\t", 1)
            mode, oid, stage = header.decode("ascii").split()
            if stage != "0" and not allow_unmerged:
                raise ViewError(f"unresolved index entry: {_name(name)!r}")
            entries.append((_name(name), mode, oid))
        return raw, list({name: (name, mode, oid) for name, mode, oid in entries}.values())

    @staticmethod
    def _tree(repo: Path, commit: str, store: bool):
        raw = _git(repo, "ls-tree", "-r", "-z", commit, store=store)
        entries = []
        for record in raw.split(b"\0"):
            if record:
                header, name = record.split(b"\t", 1)
                mode, _, oid = header.decode("ascii").split()
                entries.append((_name(name), mode, oid))
        return entries

    @staticmethod
    def _visible(path: Path) -> tuple[str, bytes, os.stat_result]:
        # Walk every ancestor using directory descriptors. Even a concurrent
        # symlink replacement cannot redirect a read outside the selected tree.
        directory = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for component in path.parts[1:-1]:
                next_dir = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                   dir_fd=directory)
                os.close(directory)
                directory = next_dir
            before = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
            if stat.S_ISLNK(before.st_mode):
                mode, data = "120000", os.fsencode(os.readlink(path.name, dir_fd=directory))
            elif stat.S_ISREG(before.st_mode):
                mode = "100755" if before.st_mode & 0o111 else "100644"
                fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
                with os.fdopen(fd, "rb") as source:
                    opened = os.fstat(source.fileno())
                    if _stamp(opened) != _stamp(before):
                        raise ViewError(f"entry changed during capture: {str(path)!r}")
                    data = source.read()
                    if _stamp(opened) != _stamp(os.fstat(source.fileno())):
                        raise ViewError(f"file changed during capture: {str(path)!r}")
            elif stat.S_ISDIR(before.st_mode):
                mode, data = "040000", b""
            else:
                raise ViewError(f"unsupported working-tree entry type: {str(path)!r}")
            after = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
            if _stamp(before) != _stamp(after):
                raise ViewError(f"entry changed during capture: {str(path)!r}")
            return mode, data, after
        finally:
            os.close(directory)

    def _child(self, repo: Path, path: str, modules: bytes, *, working: bool,
               store: bool, oid: str) -> tuple[Path, bool] | None:
        checkout = repo / path
        usable_checkout = not store
        if not store:
            for index in range(1, len(Path(path).parts) + 1):
                if (repo.joinpath(*Path(path).parts[:index])).is_symlink():
                    if working:
                        raise ViewError(f"symlink submodule mount: {path!r}")
                    usable_checkout = False
                    break
        populated = usable_checkout and (checkout / ".git").exists()
        if working:
            return (checkout, False) if populated else None
        # Read names from the selected view's .gitmodules, never live config.
        config = subprocess.run(["git", "config", "--null", "--file", "-",
                                 "--get-regexp", r"^submodule\..*\.path$"],
                                input=modules, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if config.returncode not in (0, 1):
            raise ViewError("invalid captured .gitmodules")
        for record in config.stdout.split(b"\0"):
            if not record:
                continue
            key, value = record.split(b"\n", 1)
            if _name(value) == path:
                name = _safe(_name(key)[len("submodule."):-len(".path")])
                if not name:
                    raise ViewError("empty submodule name")
                # rev-parse --git-path respects common dirs in linked worktrees.
                location = _name(_git(repo, "rev-parse", "--git-path", "modules/" + name, store=store)[:-1])
                candidate = Path(location)
                if not candidate.is_absolute():
                    candidate = repo / candidate
                if candidate.is_dir():
                    try:
                        _git(candidate, "cat-file", "-e", oid + "^{commit}", store=True)
                    except ViewError:
                        continue
                    return candidate, True
        return (checkout, False) if populated else None

    def _capture(self, repo: Path, owner: str, commit: str | None, store: bool = False):
        identity = (str(repo.resolve()), commit)
        if identity in self._active:
            raise ViewError("recursive repository cycle")
        self._active.add(identity)
        try:
            working = self.mode == "working-tree"
            if commit is None:
                baseline, entries = self._index(repo, allow_unmerged=working)
            else:
                baseline, entries = None, self._tree(repo, commit, store)
            entries = [(_safe(name), mode, oid) for name, mode, oid in entries]
            tracked = {name for name, _, _ in entries}
            if working:
                others = _git(repo, "ls-files", "--others", "--exclude-standard", "-z")
                entries += [(_safe(_name(name)), "", "") for name in others.split(b"\0") if name]
            # Establish visible types before copying. If a tracked directory
            # became a file/symlink, its hidden descendants are no longer visible;
            # capture the replacing ancestor once, without following it.
            initial = {}
            if working:
                visible = {}
                for name, mode, oid in entries:
                    if mode == "160000":
                        visible[name] = (name, mode, oid)
                        continue
                    parts = name.split("/")
                    for index in range(len(parts)):
                        selected = "/".join(parts[:index + 1])
                        live = repo / selected
                        try:
                            stamp = live.lstat()
                        except FileNotFoundError:
                            break
                        if index < len(parts) - 1 and stat.S_ISDIR(stamp.st_mode):
                            continue
                        initial[selected] = stamp
                        visible[selected] = (selected, mode, oid)
                        break
                entries = list(visible.values())
            captured = []
            children = []
            modules = b""
            for name, mode, oid in entries:
                name = _safe(name)
                logical = posixpath.join(owner, name)
                if mode == "160000":
                    children.append((name, logical, oid))
                    continue
                if working:
                    live = repo / name
                    mode, data, stamp = self._visible(live)
                    if _stamp(stamp) != _stamp(initial[name]):
                        raise ViewError(f"entry changed during capture: {logical!r}")
                    captured.append((live, stamp))
                else:
                    if mode not in ("100644", "100755", "120000"):
                        raise ViewError(f"unsupported index mode: {mode}")
                    data = _git(repo, "cat-file", "blob", oid, store=store)
                origin = "tracked" if name in tracked else "untracked"
                self._put(logical, owner, origin, mode, data)
                if name == ".gitmodules":
                    modules = data
            for name, logical, oid in children:
                child = self._child(repo, name, modules, working=working, store=store, oid=oid)
                self._parents(logical, owner, "tracked")
                if child is None:
                    if not working:
                        raise ViewError(f"required gitlink object unavailable: {logical!r} at {oid}")
                    self.entries[logical] = {"kind": "unavailable", "owner": owner,
                                             "origin": "tracked", "mode": "160000"}
                    self.unavailable.append(logical)
                else:
                    self.entries[logical] = {"kind": "directory", "owner": logical,
                                             "origin": "tracked", "mode": "160000"}
                    (self.root / logical).mkdir(exist_ok=True)
                    self._capture(child[0], logical, None if working else oid, child[1])
            for path, stamp in captured:
                if _stamp(path.lstat()) != _stamp(stamp):
                    raise ViewError(f"entry changed during capture: {str(path)!r}")
            if baseline is not None and self._index(repo, allow_unmerged=working)[0] != baseline:
                raise ViewError("index changed during capture")
            if working and _git(repo, "ls-files", "--others", "--exclude-standard", "-z") != others:
                raise ViewError("untracked paths changed during capture")
        finally:
            self._active.remove(identity)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    run = commands.add_parser("run", help="capture a view, run a command, then clean up")
    run.add_argument("--mode", choices=("working-tree", "index"), default="working-tree",
                     help="visible tracked + non-ignored untracked bytes, or exact staged objects")
    run.add_argument("--repo", required=True)
    run.add_argument("command", nargs=argparse.REMAINDER)
    listing = commands.add_parser("list", help="write captured non-directory paths, NUL delimited")
    listing.add_argument("--manifest", required=True)
    listing.add_argument("--owner")
    listing.add_argument("--origin", choices=("tracked", "untracked"))
    listing.add_argument("--suffix", default="")
    resolve = commands.add_parser("resolve", help="write a confined logical path, NUL terminated")
    resolve.add_argument("--manifest", required=True)
    resolve.add_argument("path")
    args = parser.parse_args(argv)
    try:
        if args.action == "run":
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            if not command:
                parser.error("run requires a consumer command")
            with RepositoryView(args.repo, args.mode) as view:
                env = dict(os.environ, REPOSITORY_VIEW_ROOT=str(view.root),
                           REPOSITORY_VIEW_MANIFEST=str(view.manifest))
                process = subprocess.Popen(command, env=env)
                previous = {}
                def forward(signum, _frame):
                    process.send_signal(signum)
                try:
                    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
                        previous[signum] = signal.signal(signum, forward)
                    code = process.wait()
                finally:
                    for signum, handler in previous.items():
                        signal.signal(signum, handler)
                return code if code >= 0 else 128 - code
        view = ManifestView.load(args.manifest)
        paths = (view.paths(owner=args.owner, origin=args.origin, suffix=args.suffix)
                 if args.action == "list" else [view.resolve(args.path)])
        for path in paths:
            sys.stdout.buffer.write(os.fsencode(path) + b"\0")
        return 0
    except (ViewError, OSError) as exc:
        print(f"repository view unavailable: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
