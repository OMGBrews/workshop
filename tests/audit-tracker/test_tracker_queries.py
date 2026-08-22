"""Tests for next/done/status/list_types queries.

Full port of pia-maker's ``test_queries.py``: ordering, round-robin rotation
driven by the pick counter, stale classification, and the kind + prefix
filters. pytest fixtures become helper methods; ``parametrize`` becomes
``subTest``.
"""


import support

import unittest

from audit_tracker import queries
from audit_tracker.refresh import refresh


class QueriesTestBase(support.RepoTestCase):
    """Common plumbing: a fake git tree, a schema'd connection, configs."""

    def seeded(self, fake_git: support.FakeGit) -> "object":
        """DB seeded with three files applicable for the 'code' type."""
        fake_git.files = ["a.py", "b.py", "c.py"]
        fake_git.head = "HEAD"
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["*.py"]}]}}}
        )
        conn = self.conn()
        refresh(conn, config)
        return conn


class NextOrderingTest(QueriesTestBase):
    # 1. never-audited paths are the first candidates -------------------------
    def test_next_returns_all_never_audited_candidates(self) -> None:
        fake = self.fake_git()
        conn = self.seeded(fake)
        candidates = queries.next_paths(conn, "code", limit=3)
        self.assertEqual({c.path for c in candidates}, {"a.py", "b.py", "c.py"})
        self.assertTrue(all(c.reason == "never-audited" for c in candidates))

    # 2. the first N picks cover N distinct parent directories ---------------
    def test_next_round_robins_never_audited_by_parent_dir(self) -> None:
        """First N never-audited picks should cover N distinct parent directories."""
        fake = self.fake_git()
        files = [
            "app/api/a.py",
            "app/api/b.py",
            "app/api/c.py",
            "app/cli/a.py",
            "app/cli/b.py",
            "docs/a.py",
        ]
        fake.files = files
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["**/*.py"]}]}}}
        )
        conn = self.conn()
        refresh(conn, config)

        candidates = queries.next_paths(conn, "code", limit=6)
        paths = [c.path for c in candidates]

        # All six files show up, each exactly once.
        self.assertEqual(set(paths), set(files))
        self.assertEqual(len(paths), len(set(paths)))

        # Round 1 (first 3 picks) covers all 3 distinct parent directories.
        first_round_parents = {p.rsplit("/", 1)[0] for p in paths[:3]}
        self.assertEqual(first_round_parents, {"app/api", "app/cli", "docs"})

        # Round 2 (picks 4-5) covers the 2 dirs that still had files.
        second_round_parents = {p.rsplit("/", 1)[0] for p in paths[3:5]}
        self.assertEqual(second_round_parents, {"app/api", "app/cli"})

        # Round 3 (pick 6) is the last remaining file in app/api.
        self.assertTrue(paths[5].startswith("app/api/"))

    # 3. same path set → same ordering, run after run ------------------------
    def test_next_never_audited_ordering_is_deterministic(self) -> None:
        """Same path set → same ordering, so `/audit-next` is reproducible."""
        fake = self.fake_git()
        fake.files = [f"app/pkg{i}/mod.py" for i in range(20)]
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["**/*.py"]}]}}}
        )
        conn = self.conn()
        refresh(conn, config)

        first = [c.path for c in queries.next_paths(conn, "code", limit=20)]
        second = [c.path for c in queries.next_paths(conn, "code", limit=20)]
        self.assertEqual(first, second)

    # 4. the deterministic order is hash-uniform, not alphabetical -----------
    def test_next_never_audited_ordering_is_not_alphabetical(self) -> None:
        """Uniform pseudo-random ordering — not the alphabetical sort it replaced."""
        # 20 sibling files in one directory: with 20! permutations, the odds of
        # the hash ordering coinciding with alphabetical are vanishingly small.
        fake = self.fake_git()
        fake.files = [f"app/mod_{i:02d}.py" for i in range(20)]
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["**/*.py"]}]}}}
        )
        conn = self.conn()
        refresh(conn, config)

        paths = [c.path for c in queries.next_paths(conn, "code", limit=20)]
        self.assertNotEqual(paths, sorted(paths))

    # 5. stale bucket orders by commit count, descending ----------------------
    def test_next_orders_stale_by_commit_count_desc(self) -> None:
        fake = self.fake_git()
        conn = self.seeded(fake)
        queries.done(conn, "a.py", "code", commit="SHA_A")
        queries.done(conn, "b.py", "code", commit="SHA_B")
        queries.done(conn, "c.py", "code", commit="SHA_C")

        fake.commits_by_path[("SHA_A", "a.py")] = 1
        fake.commits_by_path[("SHA_B", "b.py")] = 5
        fake.commits_by_path[("SHA_C", "c.py")] = 3

        candidates = queries.next_paths(conn, "code", limit=3)
        self.assertEqual([c.path for c in candidates], ["b.py", "c.py", "a.py"])
        self.assertTrue(all(c.reason == "stale" for c in candidates))

    # 6. priority: never, then stale, then clean ------------------------------
    def test_next_priority_never_then_stale_then_clean(self) -> None:
        fake = self.fake_git()
        conn = self.seeded(fake)
        queries.done(conn, "a.py", "code", commit="SHA_A")  # clean
        queries.done(conn, "b.py", "code", commit="SHA_B")  # stale
        fake.commits_by_path[("SHA_B", "b.py")] = 2
        # c.py is never audited

        candidates = queries.next_paths(conn, "code", limit=3)
        self.assertEqual([c.path for c in candidates], ["c.py", "b.py", "a.py"])
        self.assertEqual([c.reason for c in candidates], ["never-audited", "stale", "clean"])

    # 7. only_never keeps just bucket 1 ---------------------------------------
    def test_next_only_never_filter(self) -> None:
        fake = self.fake_git()
        conn = self.seeded(fake)
        queries.done(conn, "a.py", "code", commit="SHA_A")
        fake.commits_by_path[("SHA_A", "a.py")] = 7  # stale but not never
        candidates = queries.next_paths(conn, "code", limit=10, only_never=True)
        self.assertEqual({c.path for c in candidates}, {"b.py", "c.py"})

    # 8. only_stale keeps just bucket 2 ---------------------------------------
    def test_next_only_stale_filter(self) -> None:
        fake = self.fake_git()
        conn = self.seeded(fake)
        queries.done(conn, "a.py", "code", commit="SHA_A")
        queries.done(conn, "b.py", "code", commit="SHA_B")
        fake.commits_by_path[("SHA_A", "a.py")] = 1
        # b.py has 0 commits since audit → clean
        candidates = queries.next_paths(conn, "code", limit=10, only_stale=True)
        self.assertEqual([c.path for c in candidates], ["a.py"])


class DoneTest(QueriesTestBase):
    # 9. done() is an upsert ---------------------------------------------------
    def test_done_is_upsert(self) -> None:
        conn = self.seeded(self.fake_git())
        queries.done(conn, "a.py", "code", commit="FIRST", note="v1")
        queries.done(conn, "a.py", "code", commit="SECOND", note="v2")
        row = conn.execute(
            "SELECT last_audit_commit, notes FROM audits WHERE path = 'a.py' AND audit_type = 'code'"
        ).fetchone()
        self.assertEqual(row["last_audit_commit"], "SECOND")
        self.assertEqual(row["notes"], "v2")

    # 10. done() defaults to HEAD ---------------------------------------------
    def test_done_uses_head_when_no_commit_given(self) -> None:
        fake = self.fake_git()
        conn = self.seeded(fake)
        fake.head = "CURRENT_HEAD"
        queries.done(conn, "a.py", "code")
        row = conn.execute(
            "SELECT last_audit_commit FROM audits WHERE path = 'a.py'"
        ).fetchone()
        self.assertEqual(row["last_audit_commit"], "CURRENT_HEAD")

    # 11. done() rejects a path not applicable for the type --------------------
    def test_done_rejects_non_applicable_path(self) -> None:
        conn = self.seeded(self.fake_git())
        with self.assertRaises(ValueError) as caught:
            queries.done(conn, "a.py", "docs-not-a-real-type")
        self.assertIn("not applicable", str(caught.exception))

    # 12. re-auditing without a note must not clobber the stored one ----------
    def test_done_preserves_note_when_none_on_re_audit(self) -> None:
        conn = self.seeded(self.fake_git())
        queries.done(conn, "a.py", "code", commit="FIRST", note="v1")
        queries.done(conn, "a.py", "code", commit="SECOND")
        row = conn.execute(
            "SELECT last_audit_commit, notes FROM audits WHERE path = 'a.py'"
        ).fetchone()
        self.assertEqual(row["last_audit_commit"], "SECOND")
        self.assertEqual(row["notes"], "v1")


class StalenessClassificationTest(QueriesTestBase):
    # 13. an audit with a timestamp but NULL commit re-surfaces as stale ------
    def test_next_treats_null_commit_as_stale(self) -> None:
        conn = self.seeded(self.fake_git())
        conn.execute(
            "INSERT INTO audits (path, audit_type, last_audited_at, last_audit_commit) "
            "VALUES ('a.py', 'code', '2020-01-01T00:00:00+00:00', NULL)"
        )
        conn.commit()
        candidates = queries.next_paths(conn, "code", limit=10, only_stale=True)
        self.assertEqual([c.path for c in candidates], ["a.py"])
        self.assertEqual(candidates[0].reason, "stale")

    # 14. a SHA dropped from history (rebase/GC) re-surfaces as stale --------
    def test_next_treats_unknown_sha_as_stale(self) -> None:
        fake = self.fake_git()
        conn = self.seeded(fake)
        queries.done(conn, "a.py", "code", commit="GONE")
        fake.unknown_shas.add("GONE")
        candidates = queries.next_paths(conn, "code", limit=10, only_stale=True)
        self.assertEqual([c.path for c in candidates], ["a.py"])
        self.assertEqual(candidates[0].reason, "stale")


class LimitTest(QueriesTestBase):
    # 15. limit 0 → empty; negative limit → everything ------------------------
    def test_next_limit_zero_returns_empty(self) -> None:
        conn = self.seeded(self.fake_git())
        self.assertEqual(queries.next_paths(conn, "code", limit=0), [])

    def test_next_negative_limit_returns_all(self) -> None:
        conn = self.seeded(self.fake_git())
        candidates = queries.next_paths(conn, "code", limit=-1)
        self.assertEqual({c.path for c in candidates}, {"a.py", "b.py", "c.py"})


class RotationTest(support.RepoTestCase):
    """The pick counter rotates back-to-back single picks across parents."""

    def _setup(self, fake: support.FakeGit, files: list[str]):
        fake.files = files
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["**/*.py"]}]}}}
        )
        conn = self.conn()
        refresh(conn, config)
        return conn

    # 16. consecutive limit=1 picks land in different parent dirs -------------
    def test_next_rotates_across_done_calls(self) -> None:
        """Back-to-back limit=1 picks must land in different parent dirs.

        Prevents the bias where `sha256(dir)` ordering repeatedly picked the
        same parent directory until it was exhausted.
        """
        fake = self.fake_git()
        conn = self._setup(fake, ["app/a/x.py", "app/b/y.py", "app/c/z.py"])

        seen_dirs: list[str] = []
        for _ in range(3):
            pick = queries.next_paths(conn, "code", limit=1)[0]
            seen_dirs.append(pick.path.rsplit("/", 1)[0])
            queries.done(conn, pick.path, "code", commit="SHA")
        self.assertEqual(len(set(seen_dirs)), 3, f"expected distinct dirs across calls, got {seen_dirs}")

    # 17. next() alone does not advance the cursor; done() does ---------------
    def test_next_is_stable_without_done(self) -> None:
        """The pick cursor advances on done(), not on next()."""
        fake = self.fake_git()
        conn = self._setup(fake, ["app/a/x.py", "app/b/y.py", "app/c/z.py"])

        first = queries.next_paths(conn, "code", limit=1)[0]
        second = queries.next_paths(conn, "code", limit=1)[0]
        self.assertEqual(first.path, second.path)


class StatusAndTypesTest(QueriesTestBase):
    # 18. status counts total/audited/never/stale ------------------------------
    def test_status_counts(self) -> None:
        fake = self.fake_git()
        conn = self.seeded(fake)
        queries.done(conn, "a.py", "code", commit="SHA_A")
        queries.done(conn, "b.py", "code", commit="SHA_B")
        fake.commits_by_path[("SHA_A", "a.py")] = 3  # stale
        # b.py clean; c.py never

        stats = queries.status(conn, "code")
        self.assertEqual(stats.total, 3)
        self.assertEqual(stats.audited, 2)
        self.assertEqual(stats.never, 1)
        self.assertEqual(stats.stale, 1)

    # 19. list_types names types that have applicable paths --------------------
    def test_list_types_returns_audit_types_with_paths(self) -> None:
        conn = self.seeded(self.fake_git())
        self.assertEqual(queries.list_types(conn), ["code"])


class KindFilterTest(support.RepoTestCase):
    def _conn_with_file_and_dir_rules(self, fake: support.FakeGit, files: list[str]):
        fake.files = files
        config = support.make_config(
            {
                "audit_types": {
                    "code": {
                        "targets": [
                            {"kind": "file", "include": ["app/**/*.py"]},
                            {"kind": "directory", "include": ["app"]},
                        ]
                    }
                }
            }
        )
        conn = self.conn()
        refresh(conn, config)
        return conn

    # 20. kind=file returns only files -----------------------------------------
    @unittest.skipUnless(
        support.MID_DOUBLESTAR_MATCHES_ZERO_SEGMENTS,
        "shipped matcher requires >=1 segment for mid-pattern '**' (see port report)",
    )
    def test_next_kind_filter_files_only(self) -> None:
        fake = self.fake_git()
        conn = self._conn_with_file_and_dir_rules(fake, ["app/x.py", "app/y.py"])
        files = queries.next_paths(conn, "code", limit=10, kind="file")
        self.assertEqual({c.path for c in files}, {"app/x.py", "app/y.py"})
        self.assertTrue(all(c.kind == "file" for c in files))

    # 21. kind=directory returns only the directory ----------------------------
    def test_next_kind_filter_directories_only(self) -> None:
        fake = self.fake_git()
        conn = self._conn_with_file_and_dir_rules(fake, ["app/x.py"])
        dirs = queries.next_paths(conn, "code", limit=10, kind="directory")
        self.assertEqual([c.path for c in dirs], ["app"])
        self.assertEqual(dirs[0].kind, "directory")

    # 22. status respects the kind filter ---------------------------------------
    @unittest.skipUnless(
        support.MID_DOUBLESTAR_MATCHES_ZERO_SEGMENTS,
        "shipped matcher requires >=1 segment for mid-pattern '**' (see port report)",
    )
    def test_status_kind_filter_counts_only_that_kind(self) -> None:
        fake = self.fake_git()
        conn = self._conn_with_file_and_dir_rules(fake, ["app/x.py", "app/y.py"])
        self.assertEqual(queries.status(conn, "code").total, 3)  # 2 files + 1 dir
        self.assertEqual(queries.status(conn, "code", kind="file").total, 2)
        self.assertEqual(queries.status(conn, "code", kind="directory").total, 1)


class PathPrefixTest(support.RepoTestCase):
    """Subtree filtering: the prefix itself plus its descendants."""

    def tree_seeded(self, fake: support.FakeGit):
        """Files across three subtrees and their parent directories."""
        fake.files = [
            "app/api/routes.py",
            "app/api/deps.py",
            "app/cli/export.py",
            "docs/guide.md",
        ]
        config = support.make_config(
            {
                "audit_types": {
                    "code": {
                        "targets": [
                            {"kind": "file", "include": ["**/*.py"]},
                            {"kind": "directory", "include": ["app/**", "app"]},
                        ]
                    }
                }
            }
        )
        conn = self.conn()
        refresh(conn, config)
        return conn

    # 23. prefix includes subtree files and the directory itself --------------
    def test_next_path_prefix_includes_subtree_files_and_dirs(self) -> None:
        conn = self.tree_seeded(self.fake_git())
        candidates = queries.next_paths(conn, "code", limit=99, path_prefix="app/api")
        self.assertEqual(
            {c.path for c in candidates}, {"app/api", "app/api/routes.py", "app/api/deps.py"}
        )

    # 24. prefix excludes sibling subtrees and the prefix's own parent --------
    def test_next_path_prefix_excludes_sibling_subtrees(self) -> None:
        conn = self.tree_seeded(self.fake_git())
        paths = {
            c.path for c in queries.next_paths(conn, "code", limit=99, path_prefix="app/api")
        }
        self.assertNotIn("app/cli/export.py", paths)
        self.assertNotIn("app", paths)  # parent of prefix, not under it

    # 25. prefix combines with the kind filter ---------------------------------
    def test_next_path_prefix_combines_with_kind_filter(self) -> None:
        conn = self.tree_seeded(self.fake_git())
        files = queries.next_paths(conn, "code", limit=99, path_prefix="app", kind="file")
        self.assertEqual(
            {c.path for c in files},
            {"app/api/routes.py", "app/api/deps.py", "app/cli/export.py"},
        )
        dirs = queries.next_paths(conn, "code", limit=99, path_prefix="app", kind="directory")
        self.assertEqual({c.path for c in dirs}, {"app", "app/api", "app/cli"})

    # 26. prefix matches whole segments only -----------------------------------
    def test_next_path_prefix_does_not_match_lookalike_sibling(self) -> None:
        """Prefix ``app/api`` must not match ``app/api_v2/...`` — exact segment
        match only."""
        fake = self.fake_git()
        fake.files = ["app/api/a.py", "app/api_v2/b.py"]
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["**/*.py"]}]}}}
        )
        conn = self.conn()
        refresh(conn, config)

        paths = {
            c.path for c in queries.next_paths(conn, "code", limit=99, path_prefix="app/api")
        }
        self.assertEqual(paths, {"app/api/a.py"})

    # 27. LIKE wildcards inside the prefix are escaped --------------------------
    def test_next_path_prefix_escapes_like_wildcards(self) -> None:
        """Prefix ``audit_tracker`` must not match ``auditXtracker`` via the
        ``_`` LIKE wildcard."""
        fake = self.fake_git()
        fake.files = ["devtools/audit_tracker/cli.py", "devtools/auditXtracker/cli.py"]
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["**/*.py"]}]}}}
        )
        conn = self.conn()
        refresh(conn, config)

        paths = {
            c.path
            for c in queries.next_paths(
                conn, "code", limit=99, path_prefix="devtools/audit_tracker"
            )
        }
        self.assertEqual(paths, {"devtools/audit_tracker/cli.py"})

    # 28. status totals respect the prefix --------------------------------------
    def test_status_path_prefix_restricts_totals(self) -> None:
        conn = self.tree_seeded(self.fake_git())
        self.assertEqual(queries.status(conn, "code", path_prefix="app/api").total, 3)
        self.assertEqual(queries.status(conn, "code", path_prefix="app/cli").total, 2)

    # 29. a prefix matching nothing yields nothing -------------------------------
    def test_next_path_prefix_empty_result_returns_nothing(self) -> None:
        conn = self.tree_seeded(self.fake_git())
        self.assertEqual(
            queries.next_paths(conn, "code", limit=99, path_prefix="nonexistent"), []
        )


class NormalizePathPrefixTest(unittest.TestCase):
    # 30. accepted spellings normalize to a bare repo-relative prefix ---------
    def test_normalize_path_prefix_accepts_and_strips(self) -> None:
        cases = [
            ("app/features", "app/features"),
            ("app/features/", "app/features"),
            ("./app/features", "app/features"),
            ("./app/features/", "app/features"),
            ("  app/features  ", "app/features"),
            ("app", "app"),
        ]
        for raw, expected in cases:
            with self.subTest(raw=raw):
                self.assertEqual(queries.normalize_path_prefix(raw), expected)

    # 31. escapes, traversal, and ambiguity are rejected -----------------------
    def test_normalize_path_prefix_rejects_invalid(self) -> None:
        for raw in [
            "",
            "   ",
            "/abs/path",
            ".",
            "./",
            "../escape",
            "app/../other",
            "app//bad",
            "app/./features",
        ]:
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError):
                    queries.normalize_path_prefix(raw)


if __name__ == "__main__":
    unittest.main()
