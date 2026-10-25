#!/usr/bin/env python3
"""Offline contracts for frozen release notes."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("notes", Path(__file__).with_name("release-notes.py"))
notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notes)


class NotesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.environment = mock.patch.dict(os.environ, {
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.git("init", "-q", "--initial-branch=main")
        self.commit("Already shipped")
        self.previous = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return notes.git(self.root, *args)

    def commit(self, subject):
        self.git("add", ".")
        self.git("commit", "--allow-empty", "-qm", subject)
        return self.git("rev-parse", "HEAD")

    def generate(self, previous=None):
        return notes.generate(
            self.root, "example/app", previous or self.previous, "2026.10.25.4", "2026.10.25.4"
        )

    def test_exact_range_categorizes_direct_changes(self):
        self.commit("add a feature")
        self.commit("fix: a bug")
        result = self.generate()
        self.assertNotIn("Already shipped", result["markdown"])
        self.assertIn("## Features and improvements", result["markdown"])
        self.assertIn("## Fixes", result["markdown"])
        self.assertEqual(result["sourceRevision"], self.git("rev-parse", "HEAD"))
        self.assertIn("https://github.com/example/app/commit/", result["markdown"])

    def test_merge_title_comes_from_pr_not_trailers_or_branch_commits(self):
        self.git("switch", "-qc", "feature")
        self.commit("Internal implementation")
        self.git("switch", "-q", "main")
        self.git("merge", "--no-ff", "-qm", "Merge pull request #12 from feature\n\nCo-authored-by: Bot", "feature")
        with mock.patch.object(notes, "pull_request", return_value=("Prevent [stale] *notes*", ["bug"])) as request:
            result = self.generate()
        request.assert_called_once_with("example/app", "12", self.git("rev-parse", "HEAD"))
        self.assertNotIn("Co-authored-by", result["markdown"])
        self.assertNotIn("Internal implementation", result["markdown"])
        self.assertIn(r"Prevent \[stale\] \*notes\* ([#12](https://github.com/example/app/pull/12))", result["markdown"])
        self.assertEqual(result["plainText"], "Fixes\n- Prevent [stale] *notes*")

    def test_squash_and_lowercase_merge_subjects(self):
        self.commit("Feature (#13)")
        self.commit("merge pull request 14: headline")
        with mock.patch.object(notes, "pull_request", return_value=("Feature", ["enhancement"])) as request:
            result = self.generate()
        self.assertEqual([call.args[1] for call in request.call_args_list], ["13", "14"])
        self.assertIn("## Features", result["markdown"])

    def test_api_must_identify_exact_merged_change(self):
        pr = {"title": "Fix", "merged_at": "2026-10-25", "merge_commit_sha": "a" * 40, "labels": []}
        with mock.patch.object(subprocess, "check_output", return_value=json.dumps(pr)):
            self.assertEqual(notes.pull_request("example/app", "12", "a" * 40), ("Fix", []))
            with self.assertRaises(ValueError):
                notes.pull_request("example/app", "12", "b" * 40)
        with mock.patch.object(notes, "pull_request", side_effect=ValueError("API denied")):
            self.commit("Merge pull request #12 from feature")
            with self.assertRaisesRegex(ValueError, "API denied"):
                self.generate()

    def test_divergent_predecessor_is_rejected(self):
        self.git("switch", "-qc", "other")
        other = self.commit("Other branch")
        self.git("switch", "-q", "main")
        self.commit("Current branch")
        with self.assertRaises(subprocess.CalledProcessError):
            self.generate(previous=other)

    def test_unchanged_build_is_explicit(self):
        self.assertIn("No source changes", self.generate()["markdown"])

    def test_public_host_pin_context_is_linked_without_reading_private_repos(self):
        def write_pin(revision):
            (self.root / "Package.resolved").write_text(json.dumps({"pins": [{
                "identity": "copilot-projects",
                "location": "https://github.com/sirfergy/copilot-projects.git",
                "state": {"revision": revision},
            }]}))
        write_pin("a" * 40)
        previous = self.commit("Old host")
        write_pin("b" * 40)
        self.commit("Update host")
        self.assertIn("compare/" + "a" * 40 + "..." + "b" * 40, self.generate(previous)["markdown"])

    def test_plain_text_limit_and_markup_independence(self):
        sections = {"Fixes": [(f"Fix {i} " + "\U0001f680" * 100, "https://example.invalid") for i in range(50)]}
        text = notes.plain_text(sections)
        self.assertLessEqual(len(text.encode("utf-16-le")) // 2, 4000)
        self.assertIn("More changes", text)
        self.assertNotIn("https", text)
        self.assertNotIn("##", text)

    def test_invalid_or_mismatched_notes_fail_validation(self):
        document = self.generate()
        with self.assertRaises(ValueError):
            notes.validate(document, document["version"], "other")
        for key, value in [("schemaVersion", 2), ("markdown", ""), ("repository", "../x"), ("sourceRevision", "main")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                notes.validate({**document, key: value}, document["version"], document["build"])


if __name__ == "__main__":
    unittest.main()
