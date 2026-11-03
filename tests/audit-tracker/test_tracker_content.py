"""Content freshness regressions using real Git snapshots and persisted records.

These tests deliberately change topology independently of content: provenance
can disappear while an audit stays fresh, and counts can grow after a revert.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import support

from audit_tracker import git_utils, queries, records
from audit_tracker.refresh import refresh
from audit_tracker.repositories import RepositoryContext


IDENTITY = ("-c", "user.email=test@example.com", "-c", "user.name=Test")


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *IDENTITY, *args], cwd=repo,
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"git {args!r} in {repo} exited {result.returncode}: {result.stderr}"
        )
    return result.stdout.strip()


def commit(repo: Path, message: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", message)
    return git(repo, "rev-parse", "HEAD")


class ContentFreshnessTest(support.RepoTestCase):
    def setUp(self) -> None:
        super().setUp()
        git(self.repo, "branch", "-M", "main")
        support.write_file(self.repo / "src/a.py", "VALUE = 1\n")
        self.initial = commit(self.repo, "initial content")
        targets = [
            {"kind": "file", "include": ["**/*.py"]},
            {"kind": "directory", "include": [".", "src", "docs", "docs/work/audits/records"]},
        ]
        self.config = support.make_config({
            "audit_types": {"code": {"targets": targets}, "other": {"targets": targets}}
        })
        self.db = self.conn()
        refresh(self.db, self.config)

    def reasons(self, audit_type: str = "code", **kwargs) -> dict[str, str]:
        return {
            candidate.path: candidate.reason
            for candidate in queries.next_paths(self.db, audit_type, limit=-1, **kwargs)
        }

    def record(self, path: str = "src/a.py", audit_type: str = "code", **kwargs) -> str:
        return queries.done(self.db, path, audit_type, **kwargs)

    def test_squash_then_fresh_clone_survives_absent_provenance(self) -> None:
        git(self.repo, "switch", "-qc", "review")
        support.write_file(self.repo / "src/a.py", "VALUE = 2\n")
        reviewed = commit(self.repo, "reviewed change")
        for path in ("src/a.py", "src", "."):
            self.record(path)
        commit(self.repo, "persist reviews")
        git(self.repo, "switch", "-q", "main")
        git(self.repo, "merge", "--squash", "review")
        git(self.repo, "commit", "-qm", "land reviewed work as squash")

        clone = self.tmp / "fresh-clone"
        git(self.tmp, "clone", "-q", "--no-local", "--single-branch", "--branch", "main", str(self.repo), str(clone))
        missing = subprocess.run(
            ["git", "cat-file", "-e", f"{reviewed}^{{commit}}"],
            cwd=clone, capture_output=True,
        )
        self.assertNotEqual(missing.returncode, 0, "fixture must actually lack the audit commit")
        os.chdir(clone)
        git_utils.reset_repo_root_cache()
        self.db = self.conn()
        refresh(self.db, self.config)
        records.load_into_db(self.db)
        def reviewed_reasons() -> dict[str, str]:
            reasons = self.reasons()
            return {path: reasons[path] for path in ("src/a.py", "src", ".")}

        self.assertEqual(reviewed_reasons(), {"src/a.py": "clean", "src": "clean", ".": "clean"})
        for row in queries.next_paths(self.db, "code", limit=-1):
            self.assertEqual(row.commits_since_audit, 0)  # unavailable, not a freshness claim

        support.write_file(clone / "src/a.py", "VALUE = 3\n")
        commit(clone, "covered edit")
        self.assertEqual(reviewed_reasons(), {"src/a.py": "stale", "src": "stale", ".": "stale"})
        support.write_file(clone / "src/a.py", "VALUE = 2\n")
        commit(clone, "exact revert")
        self.assertEqual(reviewed_reasons(), {"src/a.py": "clean", "src": "clean", ".": "clean"})

    def test_exact_revert_is_clean_despite_positive_history_count(self) -> None:
        self.record()
        support.write_file(self.repo / "src/a.py", "VALUE = 2\n")
        commit(self.repo, "edit")
        self.assertEqual(self.reasons()["src/a.py"], "stale")
        support.write_file(self.repo / "src/a.py", "VALUE = 1\n")
        commit(self.repo, "revert")
        candidate = next(c for c in queries.next_paths(self.db, "code", limit=-1) if c.path == "src/a.py")
        self.assertEqual(candidate.reason, "clean")
        self.assertEqual(candidate.commits_since_audit, 2)

    def test_nonancestor_explicit_revision_is_resolved_and_compared(self) -> None:
        git(self.repo, "switch", "-qc", "side")
        support.write_file(self.repo / "unrelated.txt", "side only\n")
        side = commit(self.repo, "different topology with matching file")
        git(self.repo, "switch", "-q", "main")
        self.assertEqual(self.record(commit=side[:10]), side)
        self.assertEqual(self.reasons()["src/a.py"], "clean")
        entry = json.loads((self.records_dir / "code.json").read_text())["audits"]["src/a.py"]
        self.assertEqual(entry["last_audit_commit"], side)
        self.assertTrue(entry["content_fingerprint"])

    def test_invalid_revision_or_missing_historical_path_leaves_records_untouched(self) -> None:
        self.record(note="keep me")
        before_json = (self.records_dir / "code.json").read_bytes()
        before_rows = [tuple(row) for row in self.db.execute("SELECT * FROM audits")]
        # Manufacture a real commit with an empty tree without changing the
        # worktree, whose current path remains applicable for done().
        git(self.repo, "read-tree", "--empty")
        empty_tree = git(self.repo, "write-tree")
        missing_path = git(self.repo, "commit-tree", empty_tree, "-m", "no audited path")
        git(self.repo, "reset", "-q", "HEAD")
        for revision in ("not-a-real-revision", missing_path):
            with self.subTest(revision=revision):
                with self.assertRaises(ValueError):
                    self.record(commit=revision)
                self.assertEqual((self.records_dir / "code.json").read_bytes(), before_json)
                self.assertEqual([tuple(row) for row in self.db.execute("SELECT * FROM audits")], before_rows)

    def test_legacy_nonancestor_evidence_is_derived_without_rewriting_json(self) -> None:
        git(self.repo, "switch", "-qc", "side")
        support.write_file(self.repo / "other.txt", "side\n")
        side = commit(self.repo, "old review on another branch")
        git(self.repo, "switch", "-q", "main")
        records.write_record("code", "src/a.py", last_audited_at="old-time", last_audit_commit=side, notes="legacy")
        before = (self.records_dir / "code.json").read_bytes()
        records.load_into_db(self.db)
        self.assertEqual(self.reasons()["src/a.py"], "clean")
        self.assertEqual((self.records_dir / "code.json").read_bytes(), before)
        support.write_file(self.repo / "src/a.py", "VALUE = 9\n")
        commit(self.repo, "changed")
        self.assertEqual(self.reasons()["src/a.py"], "stale")
        records.write_record("code", "src/a.py", last_audited_at="old-time", last_audit_commit="f" * 40, notes="legacy")
        records.load_into_db(self.db)
        self.assertEqual(self.reasons()["src/a.py"], "stale")

    def test_directory_records_and_subject_pointer_exclusions_preserve_coverage(self) -> None:
        support.write_file(self.repo / "docs/guide.md", "guide\n")
        git(self.repo, "add", "docs/guide.md")
        git(self.repo, "update-index", "--add", "--cacheinfo", f"160000,{self.initial},library")
        git(self.repo, "commit", "-qm", "add documentation and subject pointer")
        pointer_before = git(self.repo, "rev-parse", "HEAD")
        refresh(self.db, self.config)
        for path in (".", "docs"):
            self.record(path, subject_paths=["library"])
        git(self.repo, "add", records.RECORDS_SUBDIR)
        git(self.repo, "commit", "-qm", "record directory audits")
        git(self.repo, "update-index", "--add", "--cacheinfo", f"160000,{pointer_before},library")
        git(self.repo, "commit", "-qm", "move subject pointer only")
        self.assertEqual(self.reasons(subject_paths=["library"])["."], "clean")
        self.assertEqual(self.reasons(subject_paths=["library"])["docs"], "clean")
        # A file outside this audit type's file patterns is still directory content.
        support.write_file(self.repo / "docs/guide.md", "changed guide\n")
        commit(self.repo, "covered markdown change")
        self.assertEqual(self.reasons(subject_paths=["library"])["."], "stale")
        self.assertEqual(self.reasons(subject_paths=["library"])["docs"], "stale")

    def test_audit_inside_records_directory_still_covers_record_changes(self) -> None:
        support.write_file(self.records_dir / "example.json", '{"example": 1}\n')
        commit(self.repo, "existing records content")
        refresh(self.db, self.config)
        self.record("docs/work/audits/records")
        commit(self.repo, "new record is covered when reviewing the records folder")
        self.assertEqual(self.reasons()["docs/work/audits/records"], "stale")

    def test_changed_policy_and_replaced_evidence_do_not_reuse_freshness(self) -> None:
        self.record(".")
        self.assertEqual(self.reasons()["."], "clean")
        # Coverage-policy differences invalidate saved evidence even at the same HEAD.
        self.assertEqual(self.reasons(subject_paths=["library"])["."], "stale")
        self.record(".", subject_paths=["library"])
        self.assertEqual(self.reasons(subject_paths=["library"])["."], "clean")
        self.db.execute("DELETE FROM staleness_cache")
        self.assertEqual(self.reasons(subject_paths=["library"])["."], "clean")
        self.record(audit_type="other")
        self.record()
        self.assertEqual(self.reasons()["src/a.py"], "clean")
        self.db.execute("UPDATE audits SET content_fingerprint = 'incompatible-evidence' WHERE audit_type = 'other'")
        self.assertEqual(self.reasons("other")["src/a.py"], "stale")
        self.assertEqual(self.reasons()["src/a.py"], "clean")

    def test_nested_repository_uses_its_own_snapshot_and_accepts_nonancestor(self) -> None:
        library = self.repo / "library"
        library.mkdir()
        git(library, "init", "-q")
        git(library, "branch", "-M", "main")
        support.write_file(library / "src/a.py", "SUBJECT = 1\n")
        commit(library, "subject initial")
        git(library, "switch", "-qc", "review")
        support.write_file(library / "other.txt", "side\n")
        side = commit(library, "subject side review")
        git(library, "switch", "-q", "main")
        context = RepositoryContext("library", library, "library")
        self.db.execute("INSERT INTO paths VALUES ('library', 'src/a.py', 'file', 't', 't')")
        self.db.execute("INSERT INTO path_audit_applicability VALUES ('library', 'src/a.py', 'code')")
        self.assertEqual(self.record(repository=context, commit=side[:10]), side)
        roots = {"self": self.repo, "library": library}
        candidates = queries.next_paths(self.db, "code", limit=-1, roots=roots, repository="library")
        self.assertEqual([(c.path, c.reason) for c in candidates], [("src/a.py", "clean")])
        self.assertTrue((self.records_dir / "library/code.json").exists())
        self.assertFalse((library / records.RECORDS_SUBDIR).exists())
        with self.assertRaises(ValueError):
            self.record(repository=context, commit=self.initial)
        support.write_file(library / "src/a.py", "SUBJECT = 2\n")
        commit(library, "subject changed")
        self.assertEqual(queries.next_paths(self.db, "code", limit=-1, roots=roots, repository="library")[0].reason, "stale")

    def test_snapshot_identity_tracks_modes_names_and_commit_not_index(self) -> None:
        before = git_utils.content_fingerprints("HEAD", ["src/a.py", "src", "."])
        support.write_file(self.repo / "src/a.py", "UNCOMMITTED = True\n")
        git(self.repo, "add", "src/a.py")
        self.assertEqual(git_utils.content_fingerprints("HEAD", ["src/a.py", "src", "."]), before)
        git(self.repo, "reset", "--hard", "-q", "HEAD")
        git(self.repo, "update-index", "--chmod=+x", "src/a.py")
        git(self.repo, "commit", "-qm", "executable mode only")
        after_mode = git_utils.content_fingerprints("HEAD", ["src/a.py", "src", "."])
        self.assertTrue(all(before[path] != after_mode[path] for path in before))
        git(self.repo, "mv", "src/a.py", "src/name\twith\nseparators.py")
        commit(self.repo, "rename with unusual path bytes")
        self.assertNotEqual(git_utils.content_fingerprints("HEAD", ["src"])["src"], after_mode["src"])
        self.assertEqual(git_utils.content_fingerprints("not-a-commit", ["src"]), {})
        self.assertEqual(git_utils.content_fingerprints("HEAD", ["missing"]), {})
