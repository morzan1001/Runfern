import os
import pathlib
import unittest
from unittest.mock import patch

import reuse_image


class ImageReuseTests(unittest.TestCase):
    def setUp(self):
        self.source = "a" * 40
        self.current = "b" * 40
        self.run = {"path": ".github/workflows/publish-linux-base.yml", "event": "workflow_dispatch",
                    "head_branch": "main", "head_repository": {"full_name": "morzan1001/Runfern"},
                    "head_sha": self.source}
        self.signed = True
        self.comparison = "ahead"
        self.job = {"name": "Build debian-13-arm64", "status": "completed", "conclusion": "success"}
        self.artifact = {"name": "image-debian-13-arm64", "expired": False, "digest": "sha256:" + "c" * 64}
        self.environment = patch.dict(os.environ, {"GITHUB_REPOSITORY": "morzan1001/Runfern",
                                      "GITHUB_REF": "refs/heads/main", "GITHUB_RUN_ID": "20"})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def api(self, path):
        if path.endswith("/10"):
            return self.run
        if "/commits/" in path:
            return {"commit": {"verification": {"verified": self.signed}}}
        if "/compare/" in path:
            return {"status": self.comparison}
        if "/jobs?" in path:
            return {"jobs": [self.job]}
        if "/artifacts?" in path:
            return {"artifacts": [self.artifact]}
        self.fail("Unexpected API request: " + path)

    def select(self):
        with patch.object(reuse_image, "api", side_effect=self.api), \
                patch.object(reuse_image.subprocess, "check_output", return_value=self.current):
            return reuse_image.select("10", "debian-13-arm64")

    def test_successful_main_artifact_is_reusable(self):
        self.assertEqual(self.select(), (self.source, True))

    def test_only_failed_completed_builds_are_rebuilt(self):
        self.job["conclusion"] = "failure"
        self.assertEqual(self.select(), (self.source, False))
        self.job["status"] = "in_progress"
        with self.assertRaisesRegex(RuntimeError, "still running"):
            self.select()

    def test_other_workflows_forks_and_branches_are_rejected(self):
        for field, value in (("path", ".github/workflows/other.yml"), ("event", "pull_request"),
                             ("head_branch", "feature"), ("head_repository", {"full_name": "other/repo"})):
            original = self.run[field]
            self.run[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(RuntimeError, "main image publisher"):
                self.select()
            self.run[field] = original

    def test_unsigned_or_divergent_commits_are_rejected(self):
        self.signed = False
        with self.assertRaisesRegex(RuntimeError, "not signed"):
            self.select()
        self.signed = True
        self.comparison = "diverged"
        with self.assertRaisesRegex(RuntimeError, "not an ancestor"):
            self.select()

    def test_expired_artifacts_are_not_silently_rebuilt(self):
        self.artifact["expired"] = True
        with self.assertRaisesRegex(RuntimeError, "expired"):
            self.select()

    def test_reused_evidence_must_match_the_original_workflow_commit(self):
        with patch.object(reuse_image, "select", return_value=(self.source, True)), \
                patch.object(reuse_image.image_evidence, "verify",
                             return_value={"sourceRevision": {"commit": self.current}}):
            with self.assertRaisesRegex(RuntimeError, "does not belong"):
                reuse_image.verify("10", "debian-13-arm64", pathlib.Path("/fixture"))
