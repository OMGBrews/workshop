"""Tests for the refresh command — reconciling paths + applicability.

Full port of pia-maker's ``test_refresh.py``, including the two exclusion
asymmetries the module's correctness hangs on: submodule-owned paths vanish
*before* directory derivation, while empty files are withheld from
applicability only *after* it.
"""


import support

import contextlib
import io
import json
import unittest

from audit_tracker import queries, records
from audit_tracker.refresh import refresh


def all_paths(conn) -> dict[str, str]:
    return {row["path"]: row["kind"] for row in conn.execute("SELECT path, kind FROM paths")}


def applicability(conn) -> set[tuple[str, str]]:
    return {
        (row["path"], row["audit_type"])
        for row in conn.execute("SELECT path, audit_type FROM path_audit_applicability")
    }


class RefreshTest(support.RepoTestCase):
    # 1. files are tracked and their parents derived as directories ----------
    def test_refresh_populates_files_and_derived_directories(self) -> None:
        fake = self.fake_git()
        fake.files = ["app/api/routes.py", "docs/README.md"]
        config = support.make_config(
            {
                "audit_types": {
                    "code": {"targets": [{"kind": "file", "include": ["app/**/*.py"]}]}
                }
            }
        )

        conn = self.conn()
        summary = refresh(conn, config)

        self.assertEqual(
            all_paths(conn),
            {
                "app/api/routes.py": "file",
                "docs/README.md": "file",
                "app": "directory",
                "app/api": "directory",
                "docs": "directory",
            },
        )
        self.assertEqual(summary.added_paths, 5)
        self.assertEqual(summary.removed_paths, 0)
        self.assertEqual(summary.total_paths, 5)

    # 2. applicability filters by each rule, includes and excludes ------------
    @unittest.skipUnless(
        support.MID_DOUBLESTAR_MATCHES_ZERO_SEGMENTS,
        "shipped matcher requires >=1 segment for mid-pattern '**' (see port report)",
    )
    def test_applicability_filters_by_rule(self) -> None:
        fake = self.fake_git()
        fake.files = [
            "app/api/routes.py",
            "app/frontend/dist/bundle.js",
            "docs/overview.md",
        ]
        config = support.make_config(
            {
                "audit_types": {
                    "code": {
                        "targets": [
                            {
                                "kind": "file",
                                "include": ["app/**/*.py"],
                                "exclude": ["**/dist/**"],
                            }
                        ]
                    },
                    "docs": {"targets": [{"kind": "file", "include": ["docs/**/*.md"]}]},
                    "readme": {
                        "targets": [{"kind": "directory", "include": ["app/**", "docs"]}]
                    },
                }
            }
        )

        conn = self.conn()
        refresh(conn, config)

        app = applicability(conn)
        self.assertIn(("app/api/routes.py", "code"), app)
        self.assertIn(("docs/overview.md", "docs"), app)
        self.assertIn(("app/api", "readme"), app)
        self.assertIn(("docs", "readme"), app)
        self.assertNotIn(("app/frontend/dist/bundle.js", "code"), app)

    # 3. submodule-owned paths are not this repo's to audit -------------------
    def test_refresh_excludes_submodule_owned_paths(self) -> None:
        """Paths a submodule owns are not this repo's to audit.

        Git reports a symlink as an ordinary file, so without the exclusion the
        tracker offers a path whose fixes land in the submodule's working tree
        and are overwritten by the next upstream publish.
        """
        fake = self.fake_git()
        fake.files = [
            "devtools/scripts/local.py",
            "devtools/scripts/format_ci_failure.py",
            "workshop",
        ]
        fake.submodule_owned = {"devtools/scripts/format_ci_failure.py", "workshop"}
        config = support.make_config(
            {
                "audit_types": {
                    "code": {"targets": [{"kind": "file", "include": ["devtools/**/*.py"]}]}
                }
            }
        )

        conn = self.conn()
        refresh(conn, config)

        paths = all_paths(conn)
        self.assertNotIn("devtools/scripts/format_ci_failure.py", paths)
        self.assertNotIn("workshop", paths)
        self.assertEqual(paths["devtools/scripts/local.py"], "file")
        # The parent survives, because a real local file still lives there.
        self.assertEqual(paths["devtools/scripts"], "directory")

        app = applicability(conn)
        self.assertIn(("devtools/scripts/local.py", "code"), app)
        self.assertNotIn(("devtools/scripts/format_ci_failure.py", "code"), app)

    def test_refresh_excludes_all_tracked_symlinks(self) -> None:
        fake = self.fake_git()
        fake.files = ["app/real.py", "app/local-link.py", "app/external-link.py"]
        fake.symlink_files = {"app/local-link.py", "app/external-link.py"}
        config = support.make_config(
            {
                "audit_types": {
                    "code": {"targets": [{"kind": "file", "include": ["app/*.py"]}]}
                }
            }
        )
        conn = self.conn()
        refresh(conn, config)

        self.assertIn(("app/real.py", "code"), applicability(conn))
        self.assertNotIn("app/local-link.py", all_paths(conn))
        self.assertNotIn("app/external-link.py", all_paths(conn))

    # 4. submodule exclusion happens before directory derivation --------------
    def test_refresh_derives_no_directories_from_submodule_owned_paths(self) -> None:
        """Exclusion happens before directory derivation, not after.

        Filtering afterwards would leave behind directory rows that exist only
        because an excluded path passed through them — auditable paths whose
        whole contents belong to somebody else.
        """
        fake = self.fake_git()
        fake.files = ["app/x.py", "vendor/pinned/deep/thing.py"]
        fake.submodule_owned = {"vendor/pinned/deep/thing.py"}
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "directory", "include": ["**"]}]}}}
        )

        conn = self.conn()
        refresh(conn, config)

        paths = all_paths(conn)
        self.assertNotIn("vendor", paths)
        self.assertNotIn("vendor/pinned", paths)
        self.assertNotIn("vendor/pinned/deep", paths)
        self.assertEqual(paths["app"], "directory")

    # 5. empty files are withheld from every type's candidates ----------------
    def test_refresh_withholds_empty_files_from_every_audit_type(self) -> None:
        """A zero-byte file is never offered as a candidate, for any type.

        Auditing one can only ever conclude "it is empty", and an empty package
        marker matches several types' globs at once — so the property is
        asserted per type, not just over the pool as a whole.
        """
        fake = self.fake_git()
        fake.files = [
            "app/features/__init__.py",
            "app/features/engine.py",
            "tests/unit/__init__.py",
        ]
        fake.empty_files = {"app/features/__init__.py", "tests/unit/__init__.py"}
        config = support.make_config(
            {
                "audit_types": {
                    "code": {"targets": [{"kind": "file", "include": ["**/*.py"]}]},
                    "coverage": {"targets": [{"kind": "file", "include": ["**/*.py"]}]},
                }
            }
        )
        conn = self.conn()

        refresh(conn, config)

        app = applicability(conn)
        for audit_type in ("code", "coverage"):
            self.assertNotIn(("app/features/__init__.py", audit_type), app)
            self.assertNotIn(("tests/unit/__init__.py", audit_type), app)
            self.assertIn(("app/features/engine.py", audit_type), app)
            candidates = queries.next_paths(conn, audit_type, limit=10, kind="file")
            self.assertEqual([c.path for c in candidates], ["app/features/engine.py"])

        # Only applicability is withheld — the paths themselves stay tracked.
        self.assertEqual(all_paths(conn)["app/features/__init__.py"], "file")

    # 6. the predicate is emptiness, not filename ------------------------------
    def test_refresh_keeps_non_empty_init_files_applicable(self) -> None:
        """The predicate is emptiness, not filename.

        A ``__init__.py`` with re-exports in it is legitimately audit-worthy —
        the project's "thin ``__init__.py``" rule is a rule *about* such files —
        so a filename-based exclusion would be wrong even though it would pass
        the test above.
        """
        fake = self.fake_git()
        fake.files = ["app/features/__init__.py", "app/api/__init__.py"]
        fake.empty_files = {"app/api/__init__.py"}
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["**/*.py"]}]}}}
        )

        conn = self.conn()
        refresh(conn, config)

        app = applicability(conn)
        self.assertIn(("app/features/__init__.py", "code"), app)
        self.assertNotIn(("app/api/__init__.py", "code"), app)

    # 7. emptiness filters applicability after derivation, not paths ----------
    def test_refresh_keeps_directories_whose_only_file_is_empty(self) -> None:
        """Emptiness is filtered *after* directory derivation, not before.

        The mirror image of the submodule case above, and the reason the two
        filters cannot be tidied up next to each other: a package directory
        whose only tracked file is an empty marker is still ours, and still has
        a README worth auditing. Filtering the files first would erase it from
        the directory-kind pools silently.
        """
        fake = self.fake_git()
        fake.files = ["app/x.py", "app/plugins/__init__.py"]
        fake.empty_files = {"app/plugins/__init__.py"}
        config = support.make_config(
            {
                "audit_types": {
                    "readme": {"targets": [{"kind": "directory", "include": ["**"]}]},
                    "code": {"targets": [{"kind": "file", "include": ["**/*.py"]}]},
                }
            }
        )

        conn = self.conn()
        refresh(conn, config)

        self.assertEqual(all_paths(conn)["app/plugins"], "directory")
        app = applicability(conn)
        self.assertIn(("app/plugins", "readme"), app)
        self.assertNotIn(("app/plugins/__init__.py", "code"), app)

    # 8. audits recorded against empty paths stay loadable, not orphaned ------
    def test_refresh_leaves_existing_records_on_empty_paths_loadable(self) -> None:
        """Audits already recorded against empty paths survive the refresh.

        ``load_into_db`` drops any record whose path is missing from ``paths``
        and warns that it is "no longer in git". Dropping empty files from
        ``paths`` — rather than only from applicability — would fire that
        warning for every audit recorded before this filter existed, with a
        message that is plainly false, and would break the ``audits`` foreign
        key besides.
        """
        fake = self.fake_git()
        fake.files = ["app/empty/__init__.py", "app/x.py"]
        fake.empty_files = {"app/empty/__init__.py"}
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["**/*.py"]}]}}}
        )
        records.write_record(
            "code",
            "app/empty/__init__.py",
            last_audited_at="2026-01-01T00:00:00+00:00",
            last_audit_commit="SHA",
            notes=None,
            pick_counter=1,
        )
        conn = self.conn()

        refresh(conn, config)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            records.load_into_db(conn)

        self.assertNotIn("orphan record", stderr.getvalue())
        loaded = conn.execute("SELECT path FROM audits WHERE audit_type = 'code'").fetchall()
        self.assertEqual([row["path"] for row in loaded], ["app/empty/__init__.py"])
        # The JSON entry is the source of truth, and survives untouched.
        on_disk = json.loads((self.records_dir / "code.json").read_text(encoding="utf-8"))
        self.assertIn("app/empty/__init__.py", on_disk["audits"])

    # 9. vanished paths are removed and their audits cascade away -------------
    def test_refresh_removes_vanished_paths_and_cascades_audits(self) -> None:
        fake = self.fake_git()
        fake.files = ["old.py", "kept.py"]
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["*.py"]}]}}}
        )
        conn = self.conn()
        refresh(conn, config)

        conn.execute(
            "INSERT INTO audits (path, audit_type, last_audited_at, last_audit_commit) "
            "VALUES (?, ?, ?, ?)",
            ("old.py", "code", "2026-01-01T00:00:00+00:00", "SHA"),
        )
        conn.commit()

        fake.files = ["kept.py"]
        summary = refresh(conn, config)

        self.assertNotIn("old.py", all_paths(conn))
        orphan_audits = conn.execute("SELECT * FROM audits WHERE path = 'old.py'").fetchall()
        self.assertEqual(orphan_audits, [])
        self.assertEqual(summary.removed_paths, 1)

    # 10. changing the config rebuilds applicability ---------------------------
    @unittest.skipUnless(
        support.MID_DOUBLESTAR_MATCHES_ZERO_SEGMENTS,
        "shipped matcher requires >=1 segment for mid-pattern '**' (see port report)",
    )
    def test_refresh_rebuilds_applicability_when_config_changes(self) -> None:
        fake = self.fake_git()
        fake.files = ["app/x.py"]
        config_v1 = support.make_config(
            {
                "audit_types": {
                    "code": {"targets": [{"kind": "file", "include": ["app/**/*.py"]}]}
                }
            }
        )
        conn = self.conn()
        refresh(conn, config_v1)
        self.assertIn(("app/x.py", "code"), applicability(conn))

        config_v2 = support.make_config(
            {
                "audit_types": {
                    "code": {"targets": [{"kind": "file", "include": ["app/**/*.py"]}]},
                    "docs": {"targets": [{"kind": "file", "include": ["app/**/*.py"]}]},
                }
            }
        )
        refresh(conn, config_v2)
        app = applicability(conn)
        self.assertIn(("app/x.py", "code"), app)
        self.assertIn(("app/x.py", "docs"), app)

    # 11. re-refreshing does not duplicate rows --------------------------------
    def test_refresh_updates_last_seen_without_duplicating(self) -> None:
        fake = self.fake_git()
        fake.files = ["a.py"]
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["*.py"]}]}}}
        )
        conn = self.conn()
        refresh(conn, config)
        refresh(conn, config)

        rows = conn.execute("SELECT path FROM paths WHERE path = 'a.py'").fetchall()
        self.assertEqual(len(rows), 1)

    # 12. every refresh records its state beside the cache --------------------
    def test_refresh_records_state(self) -> None:
        """Every refresh writes its state file so "when was the tracker last
        reconciled?" has a durable answer across cache rebuilds."""
        fake = self.fake_git()
        fake.files = ["a.py"]
        fake.head = "HEAD_AT_REFRESH"
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["*.py"]}]}}}
        )

        refresh(self.conn(), config)

        state = records.read_refresh_state(cache=self.cache)
        self.assertIsNotNone(state)
        self.assertEqual(state["last_refresh_commit"], "HEAD_AT_REFRESH")
        self.assertTrue(state["last_refreshed_at"])
        # The state file lives beside the SQLite cache, outside the repo tree.
        self.assertTrue((self.cache / "refresh-state.json").exists())

    # 13. a later refresh overwrites the earlier state -------------------------
    def test_refresh_overwrites_state_on_subsequent_runs(self) -> None:
        fake = self.fake_git()
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["*.py"]}]}}}
        )
        fake.files = ["a.py"]
        fake.head = "FIRST"
        conn = self.conn()
        refresh(conn, config)
        fake.head = "SECOND"
        refresh(conn, config)

        state = records.read_refresh_state(cache=self.cache)
        self.assertIsNotNone(state)
        self.assertEqual(state["last_refresh_commit"], "SECOND")

    # 14. a file↔directory flip at the same path updates the kind -------------
    def test_refresh_updates_kind_when_path_flips(self) -> None:
        # "foo" starts as a derived directory (because "foo/bar.py" is tracked),
        # then "foo/bar.py" is removed and a top-level file literally named
        # "foo" is tracked instead. The paths.kind column must follow.
        fake = self.fake_git()
        config = support.make_config(
            {"audit_types": {"code": {"targets": [{"kind": "file", "include": ["*"]}]}}}
        )
        conn = self.conn()
        fake.files = ["foo/bar.py"]
        refresh(conn, config)
        self.assertEqual(all_paths(conn)["foo"], "directory")

        fake.files = ["foo"]
        refresh(conn, config)
        self.assertEqual(all_paths(conn)["foo"], "file")


if __name__ == "__main__":
    unittest.main()
