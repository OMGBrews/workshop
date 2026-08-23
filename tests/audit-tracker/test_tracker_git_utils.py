"""Tests for the git wrappers — chiefly submodule ownership detection.

Ported from pia-maker's ``test_git_utils.py``. These build a real repository
on disk instead of faking git's output: the question
:func:`submodule_owned_paths` answers is "where does this symlink actually
land", and only real symlinks can answer it — the two-hop case below is
exactly what a lexical implementation gets wrong, and no fake can surface it.

The pia fixture pinned ``git_utils.REPO_ROOT``; the ported package has no
constant to pin. Instead :class:`support.RepoTestCase` chdirs the process into
the temp repo and clears the per-process ``repo_root()`` cache on both edges.

The fixture's paths are deliberately generic rather than copies of any real
repo's ones. What is under test is the *shape* of the link chain, and naming a
real template file here would cite a planning path from test code.
"""


import support

import os
import subprocess
import unittest

from audit_tracker import git_utils


# Gitlinks name a commit in *another* repository, so git never resolves this
# SHA. That is what lets a one-line `update-index` stand in for a real
# `submodule add` — the mode is the only part these tests care about.
FAKE_SUBMODULE_SHA = "1" * 40


def build_submodule_fixture(repo) -> None:
    """Lay out the link-chain shape, with the tracked kind in brackets::

        upstream-pin/                     [gitlink]
        .claude/skills/task-create        [symlink -> submodule]
        devtools/scripts/formatter.py     [symlink, one hop]
        handbook/briefs/_TEMPLATE.md      [symlink, two hops]
        devtools/scripts/local.py         [file]
        handbook/briefs/real.md           [file]
        handbook/shortcut.md              [symlink -> a local file]
    """
    # The submodule's own content. On disk it is an ordinary directory; the
    # index entry below is what makes git call it a submodule.
    support.write_file(repo / "upstream-pin/.claude/skills/task-create/_TEMPLATE.md")
    support.write_file(repo / "upstream-pin/scripts/formatter.py")
    support.run_git(
        repo,
        "update-index",
        "--add",
        "--cacheinfo",
        f"{git_utils.GITLINK_MODE},{FAKE_SUBMODULE_SHA},upstream-pin",
    )
    # Genuinely local files, which must survive the filter.
    support.write_file(repo / "devtools/scripts/local.py")
    support.write_file(repo / "handbook/briefs/real.md")
    (repo / ".claude/skills").mkdir(parents=True)
    (repo / ".claude/skills/task-create").symlink_to(
        "../../upstream-pin/.claude/skills/task-create"
    )
    (repo / "devtools/scripts/formatter.py").symlink_to(
        "../../upstream-pin/scripts/formatter.py"
    )
    # Two hops: the first component of this target is itself the directory
    # symlink above. Normalizing the link text lexically yields
    # ".claude/skills/task-create/_TEMPLATE.md", which contains no mention
    # of the submodule at all.
    (repo / "handbook/briefs/_TEMPLATE.md").symlink_to(
        "../../.claude/skills/task-create/_TEMPLATE.md"
    )
    # A symlink that stays inside this repo — ownership is about the target,
    # so being a symlink must not be enough on its own.
    (repo / "handbook/shortcut.md").symlink_to("../devtools/scripts/local.py")
    support.run_git(repo, "add", ".claude", "devtools", "handbook")


class SubmoduleOwnershipTest(support.RepoTestCase):
    def setUp(self) -> None:
        super().setUp()
        build_submodule_fixture(self.repo)

    # 1. the gitlink root itself is owned ------------------------------------
    def test_gitlink_root_is_owned(self) -> None:
        self.assertIn("upstream-pin", git_utils.submodule_owned_paths())

    # 2. one-hop symlinks landing inside the submodule are owned -------------
    def test_one_hop_symlink_into_submodule_is_owned(self) -> None:
        owned = git_utils.submodule_owned_paths()
        self.assertIn("devtools/scripts/formatter.py", owned)
        self.assertIn(".claude/skills/task-create", owned)

    # 3. the two-hop symlink resolves through the directory symlink ----------
    def test_two_hop_symlink_through_directory_symlink_is_owned(self) -> None:
        """The lexical-resolution guard.

        An implementation that normalizes the link text rather than resolving
        it passes every other test in this file and fails this one — which is
        the whole reason it is written separately.
        """
        self.assertIn("handbook/briefs/_TEMPLATE.md", git_utils.submodule_owned_paths())

    # 4. local paths — including a symlink to one — are not owned ------------
    def test_local_paths_are_not_owned(self) -> None:
        owned = git_utils.submodule_owned_paths()
        self.assertNotIn("devtools/scripts/local.py", owned)
        self.assertNotIn("handbook/briefs/real.md", owned)
        self.assertNotIn("handbook/shortcut.md", owned)

    # 5. ls_files still reports every tracked file, owned paths included -----
    def test_ls_files_still_reports_submodule_owned_paths(self) -> None:
        """``ls_files`` promises *every* tracked file, and keeps promising it.

        The filtering belongs to the tracker's universe in ``refresh``; a thin
        git wrapper that quietly omitted rows would be a worse trap than the
        one this module fixes.
        """
        files = git_utils.ls_files()
        self.assertIn("handbook/briefs/_TEMPLATE.md", files)
        self.assertIn("devtools/scripts/formatter.py", files)


class EmptyBlobTest(support.RepoTestCase):
    # 6. only zero-byte index entries are reported ---------------------------
    def test_empty_blob_paths_reports_only_zero_byte_files(self) -> None:
        """The empty-blob SHA is git's to produce, so let git produce it.

        A fake asserting :data:`git_utils.EMPTY_BLOB_SHA` against itself would
        prove nothing; what is under test is that the constant is the SHA git
        actually writes for a zero-length file in this repository's object
        format.
        """
        support.write_file(self.repo / "pkg/__init__.py", "")
        support.write_file(self.repo / "pkg/module.py", "x = 1\n")
        support.write_file(self.repo / "notes/.gitkeep", "")
        # A file that is empty on disk but not in the index: the index is what
        # the tracker reconciles against, so this must not be reported.
        support.write_file(self.repo / "staged_full.py", "y = 2\n")
        support.run_git(self.repo, "add", "pkg", "notes", "staged_full.py")
        (self.repo / "staged_full.py").write_text("", encoding="utf-8")

        self.assertEqual(
            git_utils.empty_blob_paths(), {"pkg/__init__.py", "notes/.gitkeep"}
        )

    # 7. gitlinks and symlinks can never read as empty -----------------------
    def test_empty_blob_paths_ignores_gitlinks_and_symlinks(self) -> None:
        """Neither non-blob kind can be mistaken for empty content.

        A gitlink's object is a commit and a symlink's blob holds its target,
        so comparing the object SHA alone is safe — but a repo carrying both
        pins that reasoning to a real index rather than an argument.
        """
        build_submodule_fixture(self.repo)
        self.assertEqual(git_utils.empty_blob_paths(), set())


class NoSubmodulesTest(support.RepoTestCase):
    # 8. a repo without submodules owns nothing ------------------------------
    def test_repo_without_submodules_owns_nothing(self) -> None:
        support.write_file(self.repo / "app/main.py")
        (self.repo / "link.py").symlink_to("app/main.py")
        support.run_git(self.repo, "add", "app", "link.py")
        self.assertEqual(git_utils.submodule_owned_paths(), set())
        self.assertEqual(git_utils.symlink_paths(), {"link.py"})


class RepoRootCachingTest(support.RepoTestCase):
    """The new root-resolution contract the REPO_ROOT constant replaced."""

    # 9. the root resolves from the process CWD ------------------------------
    def test_repo_root_resolves_from_process_cwd(self) -> None:
        self.assertEqual(git_utils.repo_root(), self.repo.resolve())
        self.assertEqual(git_utils.absolute_git_dir(), (self.repo / ".git").resolve())

    # 10. the cached root survives a chdir until it is explicitly reset ------
    def test_cache_survives_chdir_until_reset(self) -> None:
        first = git_utils.repo_root()
        elsewhere = self.tmp / "elsewhere"
        elsewhere.mkdir()
        os.chdir(elsewhere)
        # Still cached: the CLI is process-shaped, so mid-run chdirs must not
        # silently move the root.
        self.assertEqual(git_utils.repo_root(), first)
        # After a reset, resolution happens afresh — and outside any repository
        # that raises rather than caching garbage.
        git_utils.reset_repo_root_cache()
        with self.assertRaises(git_utils.NotARepositoryError):
            git_utils.repo_root()


class BatchHistoryTest(support.RepoTestCase):
    def setUp(self) -> None:
        super().setUp()
        support.run_git(self.repo, "config", "user.email", "test@example.com")
        support.run_git(self.repo, "config", "user.name", "Test")

    def commit(self, message: str) -> str:
        support.run_git(self.repo, "add", "-A")
        support.run_git(self.repo, "commit", "-qm", message)
        return subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=self.repo,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def test_many_counts_match_one_path_git_queries_for_multiple_shas(self) -> None:
        support.write_file(self.repo / "a.py", "a0\n")
        support.write_file(self.repo / "b.py", "b0\n")
        support.write_file(self.repo / "pkg/c.py", "c0\n")
        first = self.commit("first")
        support.write_file(self.repo / "a.py", "a1\n")
        support.write_file(self.repo / "pkg/c.py", "c1\n")
        second = self.commit("second")
        support.write_file(self.repo / "b.py", "b1\n")
        support.write_file(self.repo / "pkg/c.py", "c2\n")
        self.commit("third")

        paths = ["a.py", "b.py", "pkg", "pkg/c.py"]
        all_batched = git_utils.commits_since_many_by_sha(
            {first: paths, second: paths}
        )
        for sha in (first, second):
            with self.subTest(sha=sha):
                batched = git_utils.commits_since_many(sha, paths)
                individual = {
                    path: git_utils.commits_since(sha, path) for path in paths
                }
                self.assertEqual(batched, individual)
                self.assertEqual(all_batched[sha], individual)

    def test_index_fingerprint_is_read_only_and_tracks_staging(self) -> None:
        support.write_file(self.repo / "a.py", "a0\n")
        support.run_git(self.repo, "add", "a.py")
        before = git_utils.index_fingerprint()
        object_count_before = subprocess.run(
            ["git", "count-objects", "-v"], cwd=self.repo, check=True,
            capture_output=True, text=True,
        ).stdout
        support.write_file(self.repo / "a.py", "unstaged\n")
        self.assertEqual(git_utils.index_fingerprint(), before)
        support.run_git(self.repo, "add", "a.py")
        self.assertNotEqual(git_utils.index_fingerprint(), before)
        object_count_after = subprocess.run(
            ["git", "count-objects", "-v"], cwd=self.repo, check=True,
            capture_output=True, text=True,
        ).stdout
        # ``git add`` creates the changed blob; fingerprinting itself creates
        # no tree. A second fingerprint therefore leaves object counts stable.
        git_utils.index_fingerprint()
        self.assertEqual(
            subprocess.run(
                ["git", "count-objects", "-v"], cwd=self.repo, check=True,
                capture_output=True, text=True,
            ).stdout,
            object_count_after,
        )
        self.assertNotEqual(object_count_before, object_count_after)


class NulSafePathsTest(support.RepoTestCase):
    def test_ls_files_preserves_newline_in_tracked_filename(self) -> None:
        unusual = "odd\nname.py"
        support.write_file(self.repo / unusual)
        support.run_git(self.repo, "add", unusual)
        self.assertIn(unusual, git_utils.ls_files())


if __name__ == "__main__":
    unittest.main()
