"""Observable repository-view contracts, using disposable real Git repositories."""

import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[2] / "Tools"
sys.path.insert(0, str(TOOLS))
from repository_view import RepositoryView, ViewError  # noqa: E402


class RepositoryViewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="repository-view-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.new_repo("parent")

    def git(self, repo, *args, input=None):
        return subprocess.run(
            ["git", "-c", "protocol.file.allow=always", "-C", str(repo), *args],
            input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        ).stdout

    def new_repo(self, name):
        repo = self.base / name
        repo.mkdir()
        self.git(repo, "init", "-q")
        self.git(repo, "config", "user.name", "Fixture")
        self.git(repo, "config", "user.email", "fixture@example.invalid")
        return repo

    def write(self, repo, name, text):
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode() if isinstance(text, str) else text)
        return path

    def commit(self, repo):
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "-qm", "fixture")
        return self.git(repo, "rev-parse", "HEAD").decode().strip()

    def cli(self, repo, mode, command, **kwargs):
        return subprocess.run(
            [sys.executable, str(TOOLS / "repository_view.py"), "run",
             "--repo", str(repo), "--mode", mode, "--", *command],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, **kwargs,
        )

    def test_explicit_ignored_target_repository_is_captured_and_isolated(self):
        self.write(self.repo, ".gitignore", "external/\n")
        self.commit(self.repo)
        child = self.new_repo("parent/external")
        self.write(child, "target.md", "# Present")
        self.write(child, ".gitignore", "secret.md\n")
        self.commit(child)
        self.write(child, "secret.md", "ignored")
        with RepositoryView(self.repo, target_repositories=("external",)) as view:
            self.assertEqual(view.read_bytes("external/target.md"), b"# Present")
            self.assertEqual(view.entries["external/target.md"]["owner"], "external")
            self.assertFalse(view.exists("external/secret.md"))
            self.write(child, "target.md", "# Changed")
            self.assertEqual(view.read_bytes("external/target.md"), b"# Present")
        with self.assertRaises(ViewError):
            RepositoryView(self.repo, mode="index", target_repositories=("external",))
        for invalid in ("missing", "..", "", "external/..", "external/target.md"):
            with self.subTest(invalid=invalid), self.assertRaises(ViewError):
                with RepositoryView(self.repo, target_repositories=(invalid,)):
                    pass
        (self.repo / "alias").symlink_to(child, target_is_directory=True)
        with self.assertRaises(ViewError):
            with RepositoryView(self.repo, target_repositories=("alias",)):
                pass

    def test_working_and_index_are_distinct_stable_views(self):
        for name, text in {
            "source.md": "[target](target.md)", "target.md": "# Old",
            ".markdown-links-skip": "old.md\n", ".gitignore": "ignored/\n",
            "gone/only.md": "deleted", "shadow.md": "old shadow",
        }.items():
            self.write(self.repo, name, text)
        self.commit(self.repo)
        for name, text in {
            "source.md": "staged source", "target.md": "# Staged",
            ".markdown-links-skip": "staged.md\n",
        }.items():
            self.write(self.repo, name, text)
        self.git(self.repo, "add", "source.md", "target.md", ".markdown-links-skip")
        self.git(self.repo, "rm", "shadow.md")
        for name, text in {
            "source.md": "live source", "target.md": "# Live",
            ".markdown-links-skip": "live.md\n", "shadow.md": "untracked shadow",
            "new dir/new.md": "untracked", "ignored/hidden.md": "ignored",
        }.items():
            self.write(self.repo, name, text)
        (self.repo / "gone/only.md").unlink()
        index_before = (self.repo / ".git/index").read_bytes()
        with RepositoryView(self.repo, mode="working-tree") as working:
            with RepositoryView(self.repo, mode="index") as index:
                self.assertEqual(working.read_bytes("source.md"), b"live source")
                self.assertEqual(index.read_bytes("source.md"), b"staged source")
                self.assertEqual(working.read_bytes("target.md"), b"# Live")
                self.assertEqual(index.read_bytes("target.md"), b"# Staged")
                self.assertEqual(working.read_bytes(".markdown-links-skip"), b"live.md\n")
                self.assertEqual(index.read_bytes(".markdown-links-skip"), b"staged.md\n")
                for path in ("gone/only.md", "gone"):
                    self.assertNotIn(path, working.entries)
                    self.assertFalse(working.exists(path))
                    self.assertTrue(index.exists(path))
                self.assertTrue(index.is_dir("gone"))
                self.assertFalse(working.is_dir("gone"))
                self.assertTrue(working.is_dir("new dir"))
                self.assertFalse(index.is_dir("new dir"))
                self.assertFalse(working.exists("ignored/hidden.md"))
                self.assertFalse(working.exists("ignored"))
                self.assertEqual(working.entries["source.md"]["origin"], "tracked")
                self.assertEqual(working.entries["new dir/new.md"]["origin"], "untracked")
                self.assertEqual(working.read_bytes("shadow.md"), b"untracked shadow")
                self.assertFalse(index.exists("shadow.md"))
                self.assertNotIn("shadow.md", index.entries)
                self.assertFalse(index.exists("new dir/new.md"))
                # Once captured, input edits cannot alter either contents or facts.
                self.write(self.repo, "target.md", "# Later")
                self.write(self.repo, ".markdown-links-skip", "later.md\n")
                self.write(self.repo, ".gitignore", "new dir/\n")
                (self.repo / "new dir/new.md").unlink()
                self.assertEqual(working.read_bytes("target.md"), b"# Live")
                self.assertEqual(index.read_bytes("target.md"), b"# Staged")
                self.assertEqual(working.read_bytes(".markdown-links-skip"), b"live.md\n")
                self.assertTrue(working.exists("new dir/new.md"))
                self.assertNotEqual(working.path("target.md").stat().st_ino,
                                    (self.repo / "target.md").stat().st_ino)
                working_root, index_root = working.root, index.root
        self.assertFalse(working_root.exists())
        self.assertFalse(index_root.exists())
        self.assertEqual((self.repo / ".git/index").read_bytes(), index_before)
        self.assertEqual((self.repo / "target.md").read_bytes(), b"# Later")

    def test_byte_paths_types_and_confined_symlinks(self):
        names = ["space dir/file.md", "line\nbreak/end\n", "trailing\n/target.md",
                 "nonutf-" + os.fsdecode(b"\xff") + ".md"]
        for name in names:
            self.write(self.repo, name, b"content")
        executable = self.write(self.repo, "run", "#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        os.symlink("space dir/file.md", self.repo / "alias.md")
        os.symlink("space dir", self.repo / "dir-alias")
        os.symlink("missing", self.repo / "dangling")
        os.symlink("../outside", self.repo / "escape")
        os.symlink(str(self.base / "outside"), self.repo / "absolute")
        os.symlink("cycle-b", self.repo / "cycle-a")
        os.symlink("cycle-a", self.repo / "cycle-b")
        self.write(self.base, "outside", "must not read")
        self.commit(self.repo)
        for mode in ("working-tree", "index"):
            with self.subTest(mode=mode), RepositoryView(self.repo, mode=mode) as view:
                for name in names:
                    self.assertIn(name, view.entries)
                    self.assertEqual(view.read_bytes(name), b"content")
                    self.assertFalse(view.is_dir(name))
                self.assertEqual(view.entries["alias.md"]["kind"], "symlink")
                self.assertTrue(view.path("run").stat().st_mode & 0o111)
                self.assertEqual(view.read_bytes("alias.md"), b"content")
                self.assertEqual(view.read_bytes("dir-alias/file.md"), b"content")
                self.assertTrue(view.is_dir("dir-alias"))
                self.assertFalse(view.exists("dangling"))
                for name in ("escape", "absolute", "cycle-a"):
                    with self.subTest(link=name), self.assertRaises(ViewError):
                        view.read_bytes(name)
                # The materialized root itself never contains unsafe host links.
                self.assertFalse((view.root / "escape").is_symlink())
                self.assertFalse((view.root / "absolute").is_symlink())

    def test_independent_shell_and_python_consumers(self):
        names = ["one.md", "space name.md", "newline\nname.md", "dir\n/end\n.md"]
        for name in names:
            self.write(self.repo, name, name)
        self.commit(self.repo)
        self.write(self.repo, "new.md", "new")
        # These consumers use only the provider API; neither invokes Git.
        shell = r'''
set -euo pipefail
python3 "$1" list --manifest "$REPOSITORY_VIEW_MANIFEST" --owner '' --suffix .md > "$2"
while IFS= read -r -d '' path; do
  python3 "$1" resolve --manifest "$REPOSITORY_VIEW_MANIFEST" "$path" > "$3"
  IFS= read -r -d '' resolved < "$3"
  test "$resolved" = "$path"
  test -f "$REPOSITORY_VIEW_ROOT/$path"
  printf '%s\0' "$path"
done < "$2"
'''
        python = '''import json, os, sys
sys.path.insert(0, sys.argv[1])
from repository_view import ManifestView
view = ManifestView.load(os.environ["REPOSITORY_VIEW_MANIFEST"])
print(json.dumps({p: view.read_bytes(p).decode() for p, e in view.entries.items()
                  if e["owner"] == "" and p.endswith(".md")}))
'''
        for mode, expected in (("working-tree", names + ["new.md"]), ("index", names)):
            with self.subTest(mode=mode):
                result = self.cli(self.repo, mode, ["bash", "-c", shell, "consumer",
                                  str(TOOLS / "repository_view.py"), str(self.base / "paths"),
                                  str(self.base / "resolved")])
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual(set(result.stdout.split(b"\0")[:-1]),
                                 {os.fsencode(n) for n in expected})
                result = self.cli(self.repo, mode, [sys.executable, "-c", python, str(TOOLS)])
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual(json.loads(result.stdout),
                                 {n: "new" if n == "new.md" else n for n in expected})

    def test_cli_propagates_results_and_always_cleans_up(self):
        self.write(self.repo, "file", "unchanged")
        self.commit(self.repo)
        before = (self.repo / ".git/index").read_bytes()
        command = 'printf "%s\\0%s\\0" "$REPOSITORY_VIEW_ROOT" "$REPOSITORY_VIEW_MANIFEST"; exit "$1"'
        for mode in ("working-tree", "index"):
            for code in (0, 17):
                with self.subTest(mode=mode, code=code):
                    result = self.cli(self.repo, mode, ["bash", "-c", command, "consumer", str(code)])
                    self.assertEqual(result.returncode, code, result.stderr.decode())
                    paths = result.stdout.split(b"\0")[:-1]
                    self.assertEqual(len(paths), 2)
                    for path in paths:
                        self.assertFalse(Path(os.fsdecode(path)).exists())
        self.assertEqual((self.repo / ".git/index").read_bytes(), before)
        self.assertEqual((self.repo / "file").read_bytes(), b"unchanged")
        with self.assertRaisesRegex(RuntimeError, "consumer"):
            with RepositoryView(self.repo, mode="index") as view:
                root = view.root
                raise RuntimeError("consumer")
        self.assertFalse(root.exists())

    def test_cli_forwards_termination_and_cleans_up(self):
        self.write(self.repo, "file", "unchanged")
        self.commit(self.repo)
        before = (self.repo / ".git/index").read_bytes()
        consumer = '''import json, os, time
print(json.dumps([os.environ["REPOSITORY_VIEW_ROOT"],
                  os.environ["REPOSITORY_VIEW_MANIFEST"]]), flush=True)
time.sleep(60)
'''
        process = subprocess.Popen(
            [sys.executable, str(TOOLS / "repository_view.py"), "run",
             "--repo", str(self.repo), "--", sys.executable, "-c", consumer],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        try:
            ready, _, _ = select.select([process.stdout], [], [], 10)
            self.assertTrue(ready, "consumer did not start")
            paths = json.loads(process.stdout.readline())
            self.assertTrue(all(Path(path).exists() for path in paths))
            process.send_signal(signal.SIGTERM)
            _, errors = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM, errors.decode())
            self.assertTrue(all(not Path(path).exists() for path in paths))
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
        self.assertEqual((self.repo / ".git/index").read_bytes(), before)
        self.assertEqual((self.repo / "file").read_bytes(), b"unchanged")

    def test_working_tree_type_replacements_do_not_inherit_index_types(self):
        self.write(self.repo, "was-file", "original file")
        self.write(self.repo, "was-directory/old.md", "original subtree")
        self.write(self.repo, "was-symlink-directory/old.md", "original linked subtree")
        self.write(self.repo, "target/new.md", "new target")
        self.commit(self.repo)
        (self.repo / "was-file").unlink()
        self.write(self.repo, "was-file/new.md", "new child")
        shutil.rmtree(self.repo / "was-directory")
        self.write(self.repo, "was-directory", "replacement file")
        shutil.rmtree(self.repo / "was-symlink-directory")
        os.symlink("target", self.repo / "was-symlink-directory")
        before = (self.repo / ".git/index").read_bytes()
        with RepositoryView(self.repo, mode="working-tree") as view:
            self.assertTrue(view.is_dir("was-file"))
            self.assertEqual(view.read_bytes("was-file/new.md"), b"new child")
            self.assertFalse(view.is_dir("was-directory"))
            self.assertEqual(view.entries["was-directory"]["origin"], "untracked")
            self.assertEqual(view.read_bytes("was-directory"), b"replacement file")
            self.assertFalse(view.exists("was-directory/old.md"))
            self.assertNotIn("was-directory/old.md", view.entries)
            self.assertEqual(view.entries["was-symlink-directory"]["kind"], "symlink")
            self.assertEqual(view.entries["was-symlink-directory"]["origin"], "untracked")
            self.assertTrue(view.is_dir("was-symlink-directory"))
            self.assertEqual(view.read_bytes("was-symlink-directory/new.md"), b"new target")
            self.assertFalse(view.exists("was-symlink-directory/old.md"))
            self.assertNotIn("was-symlink-directory/old.md", view.entries)
        with RepositoryView(self.repo, mode="index") as view:
            self.assertFalse(view.is_dir("was-file"))
            self.assertEqual(view.read_bytes("was-file"), b"original file")
            self.assertFalse(view.exists("was-file/new.md"))
            self.assertTrue(view.is_dir("was-directory"))
            self.assertEqual(view.read_bytes("was-directory/old.md"), b"original subtree")
            self.assertEqual(view.entries["was-symlink-directory"]["kind"], "directory")
            self.assertEqual(view.read_bytes("was-symlink-directory/old.md"), b"original linked subtree")
        self.assertEqual((self.repo / ".git/index").read_bytes(), before)

    def test_index_rejects_conflict_and_missing_blob(self):
        self.write(self.repo, "conflict.md", "content")
        self.commit(self.repo)
        blob = self.git(self.repo, "rev-parse", "HEAD:conflict.md").strip()
        self.git(self.repo, "update-index", "--force-remove", "conflict.md")
        self.git(self.repo, "update-index", "--index-info", input=(
            b"100644 " + blob + b" 1\tconflict.md\n" +
            b"100644 " + blob + b" 2\tconflict.md\n"))
        conflicted_index = (self.repo / ".git/index").read_bytes()
        with RepositoryView(self.repo, mode="working-tree") as view:
            self.assertEqual(view.read_bytes("conflict.md"), b"content")
            self.assertEqual(list(view.paths(owner="", suffix=".md")), ["conflict.md"])
        with self.assertRaises(ViewError):
            with RepositoryView(self.repo, mode="index"):
                self.fail("unmerged index accepted")
        result = self.cli(self.repo, "index", ["true"])
        self.assertEqual(result.returncode, 2, result.stderr.decode())
        self.assertEqual((self.repo / ".git/index").read_bytes(), conflicted_index)
        self.git(self.repo, "read-tree", "HEAD")
        self.git(self.repo, "update-index", "--add", "--cacheinfo",
                 "100644," + "1" * 40 + ",absent.md")
        missing_index = (self.repo / ".git/index").read_bytes()
        with self.assertRaises(ViewError):
            with RepositoryView(self.repo, mode="index"):
                self.fail("missing object accepted")
        result = self.cli(self.repo, "index", ["true"])
        self.assertEqual(result.returncode, 2, result.stderr.decode())
        self.assertEqual((self.repo / ".git/index").read_bytes(), missing_index)

    def test_gitlinks_use_visible_child_or_exact_recorded_commit_recursively(self):
        leaf = self.new_repo("leaf")
        self.write(leaf, "leaf.md", "leaf original")
        self.commit(leaf)
        child = self.new_repo("child")
        self.write(child, "child.md", "child original")
        self.git(child, "submodule", "add", "-q", str(leaf), "nested")
        self.commit(child)
        self.write(self.repo, "parent.md", "parent")
        self.git(self.repo, "submodule", "add", "-q", str(child), "vendor child")
        self.git(self.repo, "submodule", "update", "--init", "--recursive")
        self.commit(self.repo)
        mounted = self.repo / "vendor child"
        self.git(mounted, "config", "user.name", "Fixture")
        self.git(mounted, "config", "user.email", "fixture@example.invalid")
        self.write(mounted, "child.md", "unrelated child commit")
        self.commit(mounted)
        self.write(mounted, "child.md", "dirty child")
        self.write(mounted, "untracked.md", "child untracked")
        self.write(mounted / "nested", "leaf.md", "dirty leaf")
        before = (self.repo / ".git/index").read_bytes()
        with RepositoryView(self.repo, mode="working-tree") as view:
            self.assertEqual(view.read_bytes("vendor child/child.md"), b"dirty child")
            self.assertEqual(view.read_bytes("vendor child/nested/leaf.md"), b"dirty leaf")
            self.assertEqual(view.read_bytes("vendor child/untracked.md"), b"child untracked")
            self.assertEqual(view.entries["vendor child/child.md"]["owner"], "vendor child")
            self.assertEqual(view.entries["vendor child/nested/leaf.md"]["owner"], "vendor child/nested")
            parent_sources = {p for p, e in view.entries.items()
                              if e["owner"] == "" and p.endswith(".md")}
            self.assertEqual(parent_sources, {"parent.md"})
        with RepositoryView(self.repo, mode="index") as view:
            self.assertEqual(view.read_bytes("vendor child/child.md"), b"child original")
            self.assertEqual(view.read_bytes("vendor child/nested/leaf.md"), b"leaf original")
            self.assertFalse(view.exists("vendor child/untracked.md"))
        self.assertEqual((self.repo / ".git/index").read_bytes(), before)
        self.assertEqual((mounted / "child.md").read_bytes(), b"dirty child")
        # Local cached objects suffice even after removal of the worktree.
        shutil.rmtree(mounted)
        with RepositoryView(self.repo, mode="working-tree") as view:
            self.assertIn("vendor child", view.unavailable)
        with RepositoryView(self.repo, mode="index") as view:
            self.assertEqual(view.read_bytes("vendor child/child.md"), b"child original")
            self.assertEqual(view.read_bytes("vendor child/nested/leaf.md"), b"leaf original")

        # An unrelated replacement checkout has its own objects and no copy of
        # the staged child commit. It must not hide the cached original objects.
        unrelated = self.new_repo("unrelated")
        self.write(unrelated, "child.md", "unrelated replacement")
        self.commit(unrelated)
        self.git(self.repo, "clone", "-q", str(unrelated), str(mounted))
        with RepositoryView(self.repo, mode="index") as view:
            self.assertEqual(view.read_bytes("vendor child/child.md"), b"child original")
            self.assertEqual(view.read_bytes("vendor child/nested/leaf.md"), b"leaf original")
        self.assertEqual((mounted / "child.md").read_bytes(), b"unrelated replacement")

        # Nor may a live symlink redirect exact-index object discovery into an
        # unrelated repository outside the parent's working tree.
        shutil.rmtree(mounted)
        os.symlink(unrelated, mounted)
        with RepositoryView(self.repo, mode="index") as view:
            self.assertEqual(view.read_bytes("vendor child/child.md"), b"child original")
            self.assertEqual(view.read_bytes("vendor child/nested/leaf.md"), b"leaf original")
        self.assertTrue(mounted.is_symlink())
        self.assertEqual((unrelated / "child.md").read_bytes(), b"unrelated replacement")
        self.assertEqual((self.repo / ".git/index").read_bytes(), before)

    def test_missing_gitlink_objects_fail_index_but_worktree_marks_unavailable(self):
        self.write(self.repo, ".gitmodules", '[submodule "absent"]\n path = absent\n url = nowhere\n')
        self.git(self.repo, "add", ".gitmodules")
        self.git(self.repo, "update-index", "--add", "--cacheinfo",
                 "160000," + "1" * 40 + ",absent")
        with RepositoryView(self.repo, mode="working-tree") as view:
            self.assertIn("absent", view.unavailable)
            self.assertEqual(view.entries["absent"]["kind"], "unavailable")
            with self.assertRaises(ViewError):
                view.read_bytes("absent/target.md")
        with self.assertRaises(ViewError):
            with RepositoryView(self.repo, mode="index"):
                self.fail("unavailable child object accepted")
        result = self.cli(self.repo, "index", ["true"])
        self.assertEqual(result.returncode, 2, result.stderr.decode())

    def test_unsupported_visible_file_type_is_an_error(self):
        # Replace a tracked file with a FIFO: never silently omit it or block reading.
        self.write(self.repo, "file", "ordinary")
        self.commit(self.repo)
        (self.repo / "file").unlink()
        os.mkfifo(self.repo / "file")
        result = self.cli(self.repo, "working-tree", ["true"])
        self.assertEqual(result.returncode, 2, result.stderr.decode())
        with RepositoryView(self.repo, mode="index") as view:
            self.assertEqual(view.read_bytes("file"), b"ordinary")

    def test_disappearance_during_capture_is_an_error_and_cleans_up(self):
        self.write(self.repo, "source.md", "content")
        self.commit(self.repo)
        original = RepositoryView._visible

        def disappear(path):
            path.unlink()
            return original(path)

        view = RepositoryView(self.repo)
        # Delete after discovery and the initial existence probe, so it cannot
        # be mistaken for an intentionally omitted unstaged deletion.
        with patch.object(RepositoryView, "_visible", side_effect=disappear):
            with self.assertRaises(ViewError):
                with view:
                    self.fail("capture silently omitted a disappearing file")
        self.assertFalse(view.root.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
