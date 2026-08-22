"""Tests for the JSON records module.

Ported from pia-maker's ``test_records.py`` (YAML) onto the new JSON format:
one ``<type>.json`` per audit type under ``docs/work/audits/records``, written
with ``sort_keys`` so re-recording an audit produces byte-identical files.
Refresh state moved out of the records dir entirely — it now lives beside the
SQLite cache, so its tests target a cache directory instead of a sibling file.
"""


import support

import contextlib
import io
import json
import unittest

from audit_tracker import queries, records


def seed_applicability(conn, paths: list[tuple[str, str]]) -> None:
    """Seed paths + applicability so ``done()`` accepts the writes."""
    conn.executemany(
        "INSERT INTO paths (path, kind, first_seen_at, last_seen_at) "
        "VALUES (?, 'file', '2025-01-01', '2025-01-01')",
        [(p,) for p, _ in paths],
    )
    conn.executemany(
        "INSERT INTO path_audit_applicability (path, audit_type) VALUES (?, ?)",
        paths,
    )


class RoundTripTest(support.RepoTestCase):
    """write_record + load_into_db reproduce what was written."""

    # 1. two written records load back with their fields intact --------------
    def test_round_trip_preserves_audit_rows(self) -> None:
        conn = self.conn()
        records.write_record(
            "code-quality",
            "app/foo.py",
            last_audited_at="2026-05-10T12:00:00+00:00",
            last_audit_commit="abc123",
            notes=None,
            pick_counter=3,
        )
        records.write_record(
            "code-quality",
            "app/bar.py",
            last_audited_at="2026-05-10T13:00:00+00:00",
            last_audit_commit="def456",
            notes="touched after rename",
            pick_counter=4,
        )

        seed_applicability(conn, [("app/foo.py", "code-quality"), ("app/bar.py", "code-quality")])
        records.load_into_db(conn)

        rows = sorted(
            (r["path"], r["last_audited_at"], r["last_audit_commit"], r["notes"])
            for r in conn.execute(
                "SELECT path, last_audited_at, last_audit_commit, notes "
                "FROM audits WHERE audit_type = 'code-quality'"
            )
        )
        self.assertEqual(
            rows,
            [
                ("app/bar.py", "2026-05-10T13:00:00+00:00", "def456", "touched after rename"),
                ("app/foo.py", "2026-05-10T12:00:00+00:00", "abc123", None),
            ],
        )
        counter = conn.execute(
            "SELECT pick_counter FROM audit_type_state WHERE audit_type = 'code-quality'"
        ).fetchone()
        self.assertEqual(counter["pick_counter"], 4)

    # 2. re-loading replaces the cache wholesale, never accumulates ----------
    def test_load_replaces_existing_audits(self) -> None:
        """``load_into_db`` is idempotent: re-running after a new write
        replaces the cache rows rather than accumulating duplicates."""
        conn = self.conn()
        seed_applicability(conn, [("app/foo.py", "code-quality")])
        records.write_record(
            "code-quality",
            "app/foo.py",
            last_audited_at="2026-05-10T12:00:00+00:00",
            last_audit_commit="first",
            notes=None,
            pick_counter=1,
        )
        records.load_into_db(conn)

        records.write_record(
            "code-quality",
            "app/foo.py",
            last_audited_at="2026-05-11T12:00:00+00:00",
            last_audit_commit="second",
            notes=None,
            pick_counter=2,
        )
        records.load_into_db(conn)

        rows = list(conn.execute("SELECT last_audit_commit FROM audits WHERE path = 'app/foo.py'"))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["last_audit_commit"], "second")


class FileFormatTest(support.RepoTestCase):
    """The on-disk JSON is sorted, deterministic, and parseable."""

    # 3. audits keys are sorted regardless of insertion order ----------------
    def test_keys_are_sorted_for_deterministic_diffs(self) -> None:
        records.write_record(
            "code-quality",
            "z/last.py",
            last_audited_at="t1",
            last_audit_commit="c1",
            notes=None,
            pick_counter=1,
        )
        records.write_record(
            "code-quality",
            "a/first.py",
            last_audited_at="t2",
            last_audit_commit="c2",
            notes=None,
            pick_counter=2,
        )
        text = (self.records_dir / "code-quality.json").read_text(encoding="utf-8")
        # ``a/first.py`` must appear before ``z/last.py`` regardless of
        # insertion order — this is what gives concurrent branches clean
        # text merges.
        self.assertLess(text.index('"a/first.py"'), text.index('"z/last.py"'))

    # 4. writing the identical record twice yields a byte-identical file -----
    def test_rewriting_identical_record_is_byte_identical(self) -> None:
        """Determinism is the point of sort_keys: an unchanged record set must
        not churn the file at all."""

        def _write() -> None:
            records.write_record(
                "code-quality",
                "b/middle.py",
                last_audited_at="t",
                last_audit_commit="c",
                notes=None,
                pick_counter=7,
            )
            records.write_record(
                "code-quality",
                "a/first.py",
                last_audited_at="t2",
                last_audit_commit="c2",
                notes="kept",
                pick_counter=8,
            )

        _write()
        first = (self.records_dir / "code-quality.json").read_bytes()
        _write()
        second = (self.records_dir / "code-quality.json").read_bytes()
        self.assertEqual(first, second)
        # And it is exactly what json.dumps(sorted) + trailing newline produce.
        data = json.loads(first)
        expected = (
            json.dumps(
                {
                    "pick_counter": 8,
                    "audits": {
                        "a/first.py": data["audits"]["a/first.py"],
                        "b/middle.py": data["audits"]["b/middle.py"],
                    },
                },
                sort_keys=True,
                indent=2,
                ensure_ascii=False,
            )
            + "\n"
        ).encode("utf-8")
        self.assertEqual(first, expected)

    # 5. a missing records file reads as empty, never crashes ----------------
    def test_missing_file_treated_as_empty(self) -> None:
        conn = self.conn()
        records.load_into_db(conn)
        count = conn.execute("SELECT COUNT(*) AS c FROM audits").fetchone()
        self.assertEqual(count["c"], 0)

    # 6. orphan records (path no longer in git) are skipped with a warning ---
    def test_load_into_db_skips_orphan_records(self) -> None:
        """Records can outlive a deleted path; ``load_into_db`` must skip
        them rather than crash on the audits FK, and say so on stderr."""
        conn = self.conn()
        seed_applicability(conn, [("app/lives.py", "code-quality")])
        records.write_record(
            "code-quality",
            "app/lives.py",
            last_audited_at="2026-05-10T00:00:00+00:00",
            last_audit_commit="c1",
            notes=None,
            pick_counter=1,
        )
        records.write_record(
            "code-quality",
            "app/deleted.py",
            last_audited_at="2026-05-10T00:00:00+00:00",
            last_audit_commit="c2",
            notes=None,
            pick_counter=2,
        )

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            records.load_into_db(conn)
        loaded = {r["path"] for r in conn.execute("SELECT path FROM audits")}
        self.assertEqual(loaded, {"app/lives.py"})
        err = stderr.getvalue()
        self.assertIn("orphan", err)
        self.assertIn("app/deleted.py", err)

    # 7. leading-underscore meta files are never loaded as audit types -------
    def test_load_into_db_skips_meta_files(self) -> None:
        """Leading-underscore files hold tracker meta state, not per-type
        audit records."""
        conn = self.conn()
        self.records_dir.mkdir(parents=True, exist_ok=True)
        (self.records_dir / "_meta.json").write_text(
            json.dumps({"whatever": True}), encoding="utf-8"
        )

        records.load_into_db(conn)

        type_rows = conn.execute("SELECT audit_type FROM audit_type_state").fetchall()
        self.assertTrue(all(not r["audit_type"].startswith("_") for r in type_rows))


class RefreshStateTest(support.RepoTestCase):
    """Refresh state round-trips beside the cache and survives missing reads."""

    # 8. explicit-cache round trip -------------------------------------------
    def test_round_trip_under_explicit_cache_dir(self) -> None:
        cache = self.tmp / "cache"
        records.write_refresh_state(
            last_refreshed_at="2026-05-11T12:00:00+00:00",
            last_refresh_commit="abc123",
            cache=cache,
        )
        state = records.read_refresh_state(cache=cache)
        self.assertEqual(
            state,
            {
                "last_refreshed_at": "2026-05-11T12:00:00+00:00",
                "last_refresh_commit": "abc123",
            },
        )

    # 9. the default lands inside the tracker's cache dir, not the repo tree -
    def test_default_lands_in_cache_dir(self) -> None:
        records.write_refresh_state(
            last_refreshed_at="2026-05-11T12:00:00+00:00",
            last_refresh_commit="abc123",
        )
        self.assertEqual(
            records.read_refresh_state(cache=self.cache),
            {
                "last_refreshed_at": "2026-05-11T12:00:00+00:00",
                "last_refresh_commit": "abc123",
            },
        )
        self.assertTrue((self.cache / "refresh-state.json").exists())

    # 10. reading with no state recorded returns None ------------------------
    def test_read_returns_none_when_missing(self) -> None:
        self.assertIsNone(records.read_refresh_state())


class DoneWritesJsonTest(support.RepoTestCase):
    """``queries.done()`` writes through to the JSON source of truth."""

    # 11. done persists the record and advances the pick counter -------------
    def test_done_persists_record_in_json(self) -> None:
        conn = self.conn()
        seed_applicability(conn, [("app/foo.py", "code-quality")])

        queries.done(conn, "app/foo.py", "code-quality", commit="abc123", note="first pass")

        data = json.loads((self.records_dir / "code-quality.json").read_text(encoding="utf-8"))
        self.assertEqual(data["audits"]["app/foo.py"]["last_audit_commit"], "abc123")
        self.assertEqual(data["audits"]["app/foo.py"]["notes"], "first pass")
        self.assertEqual(data["pick_counter"], 1)

    # 12. re-auditing without a note preserves the stored one ----------------
    def test_done_preserves_existing_note_when_none_passed(self) -> None:
        conn = self.conn()
        seed_applicability(conn, [("app/foo.py", "code-quality")])
        queries.done(conn, "app/foo.py", "code-quality", commit="c1", note="initial")
        queries.done(conn, "app/foo.py", "code-quality", commit="c2", note=None)

        data = json.loads((self.records_dir / "code-quality.json").read_text(encoding="utf-8"))
        self.assertEqual(data["audits"]["app/foo.py"]["notes"], "initial")
        self.assertEqual(data["audits"]["app/foo.py"]["last_audit_commit"], "c2")

    # 13. an empty-string note clears it --------------------------------------
    def test_done_clears_note_on_empty_string(self) -> None:
        conn = self.conn()
        seed_applicability(conn, [("app/foo.py", "code-quality")])
        queries.done(conn, "app/foo.py", "code-quality", commit="c1", note="initial")
        queries.done(conn, "app/foo.py", "code-quality", commit="c2", note="")

        data = json.loads((self.records_dir / "code-quality.json").read_text(encoding="utf-8"))
        self.assertNotIn("notes", data["audits"]["app/foo.py"])


if __name__ == "__main__":
    unittest.main()
