import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("submit_catalog", pathlib.Path(__file__).with_name("submit-catalog.py"))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class CatalogPRTests(unittest.TestCase):
    def test_wrong_branch_is_rejected_before_api_calls(self):
        with patch.dict(publisher.os.environ, {"GITHUB_REPOSITORY": "morzan1001/Runfern",
                                              "GITHUB_REF": "refs/heads/untrusted"}):
            with patch.object(publisher, "api") as api:
                with self.assertRaisesRegex(RuntimeError, "protected main"):
                    publisher.main()
                api.assert_not_called()

    def test_api_input_uses_stdin_not_command_line(self):
        with patch.object(publisher.subprocess, "check_output", return_value='{"ok": true}') as run:
            self.assertEqual(publisher.api("repos/example", {"value": "data"}, method="PUT"), {"ok": True})
            self.assertEqual(run.call_args.args[0], ["gh", "api", "repos/example", "--method", "PUT", "--input", "-"])
            self.assertEqual(run.call_args.kwargs["input"], '{"value": "data"}')

    def test_successful_publication_dispatches_ci_and_uses_sha_guarded_merge(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "Catalog").mkdir()
            (root / "Catalog/catalog.json").write_text("{}")
            (root / "Catalog/catalog.json.sig").write_text("signature")
            environment = {"GITHUB_REPOSITORY": "morzan1001/Runfern", "GITHUB_REF": "refs/heads/main",
                           "GITHUB_RUN_ID": "42", "GITHUB_RUN_ATTEMPT": "1",
                           "GITHUB_STEP_SUMMARY": str(root / "summary")}
            calls = []
            approval = {"required": getattr(self, "approval_mode", False)}

            def api(path, data=None, method=None):
                calls.append((path, data, method))
                if "/git/ref/heads/main" in path:
                    return {"object": {"sha": "base"}}
                if "/git/matching-refs/" in path:
                    return [{"ref": "refs/heads/publishing/catalog-42-1", "object": {"sha": "signed-head"}}]
                if "/commits/" in path and "check-runs" not in path:
                    return {"commit": {"verification": {"verified": True}}}
                if path.endswith("/pulls"):
                    return {"number": 7, "html_url": "https://github.com/morzan1001/Runfern/pull/7"}
                if "/runs?" in path:
                    if "&event=workflow_dispatch" not in path and approval["required"]:
                        return {"workflow_runs": [{
                            "head_sha": "signed-head", "head_branch": "publishing/catalog-42-1",
                            "event": "pull_request", "pull_requests": [{"number": 7}],
                            "actor": {"login": "github-actions[bot]"}, "status": "completed",
                            "conclusion": "action_required", "id": 2}]}
                    return {"workflow_runs": [{"head_sha": "signed-head", "status": "completed",
                                              "conclusion": "success", "id": 1}]}
                if path.endswith("/approve"):
                    approval["required"] = False
                    return {}
                if "check-runs" in path:
                    return {"check_runs": [{"name": "Verify the catalog", "app": {"id": 15368},
                                           "status": "completed", "conclusion": "success"}]}
                if path.endswith("/merge"):
                    return {"merged": True, "sha": "merged-head", "message": "Pull Request successfully merged"}
                return {}

            with patch.dict(publisher.os.environ, environment), patch.object(publisher, "ROOT", root), \
                    patch.object(publisher.subprocess, "check_output",
                                 side_effect=["base\n", "Catalog/catalog.json\nCatalog/catalog.json.sig\n"]), \
                    patch.object(publisher, "gh", return_value={
                        "data": {"createCommitOnBranch": {"commit": {"oid": "signed-head"}}}}), \
                    patch.object(publisher.time, "sleep"), \
                    patch.object(publisher, "api", side_effect=api):
                publisher.main()
            dispatch = next(call for call in calls if call[0].endswith("/dispatches"))
            self.assertEqual(dispatch[1], {"ref": "publishing/catalog-42-1", "inputs": {"previous": "base"}})
            merge = next(call for call in calls if call[0].endswith("/merge"))
            self.assertEqual(merge[2], "PUT")
            self.assertEqual(merge[1]["sha"], "signed-head")
            self.assertNotIn("admin", merge[1])
            self.assertEqual([call[0] for call in calls if call[2] == "DELETE"],
                             ["repos/morzan1001/Runfern/git/refs/heads/publishing/catalog-42-1"])
            if getattr(self, "approval_mode", False):
                self.assertEqual([call[0] for call in calls if call[0].endswith("/approve")],
                                 ["repos/morzan1001/Runfern/actions/runs/2/approve"])

    def test_workflow_execution_approval_is_scoped_to_the_generated_signed_pr(self):
        self.approval_mode = True
        self.test_successful_publication_dispatches_ci_and_uses_sha_guarded_merge()

    def test_branch_cleanup_never_deletes_main_or_new_unmerged_changes(self):
        with patch.object(publisher, "api") as api:
            with self.assertRaisesRegex(RuntimeError, "not an internal"):
                publisher.delete_merged_branch("morzan1001/Runfern", "main", "head")
            api.assert_not_called()
        with patch.object(publisher, "api", return_value=[
                {"ref": "refs/heads/publishing/catalog-42-1", "object": {"sha": "new-changes"}}]) as api:
            with self.assertRaisesRegex(RuntimeError, "advanced"):
                publisher.delete_merged_branch("morzan1001/Runfern", "publishing/catalog-42-1", "merged-head")
            self.assertEqual(api.call_count, 1)

    def test_already_deleted_publisher_branch_needs_no_delete(self):
        with patch.object(publisher, "api", return_value=[]) as api:
            publisher.delete_merged_branch("morzan1001/Runfern", "publishing/catalog-42-1", "merged-head")
            self.assertEqual(api.call_count, 1)


if __name__ == "__main__":
    unittest.main()
