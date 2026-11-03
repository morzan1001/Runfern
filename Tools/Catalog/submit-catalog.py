#!/usr/bin/env python3
"""Submit a GitHub-signed catalog commit and merge its PR after protected checks."""
import base64
import json
import os
import pathlib
import subprocess
import time
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[2]


def gh(*args, data=None):
    output = subprocess.check_output(["gh", *args], input=json.dumps(data) if data is not None else None,
                                     text=True, cwd=ROOT)
    return json.loads(output) if output.strip() else None


def api(path, data=None, method=None):
    args = ["api", path]
    if method:
        args += ["--method", method]
    if data is not None:
        args += ["--input", "-"]
    return gh(*args, data=data)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    repository = os.environ["GITHUB_REPOSITORY"]
    require(repository == "morzan1001/Runfern" and os.environ["GITHUB_REF"] == "refs/heads/main",
            "Catalog publication is restricted to the protected main publisher")
    base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    require(api(f"repos/{repository}/git/ref/heads/main")["object"]["sha"] == base,
            "Main advanced during publication; rerun the publisher with the existing image artifacts")
    run_id = os.environ["GITHUB_RUN_ID"]
    attempt = os.environ["GITHUB_RUN_ATTEMPT"]
    require(run_id.isdigit() and attempt.isdigit(), "Invalid workflow identity")
    branch = f"publishing/catalog-{run_id}-{attempt}"
    changed = subprocess.check_output(["git", "diff", "--name-only"], cwd=ROOT, text=True).splitlines()
    require(set(changed) <= {"Catalog/catalog.json", "Catalog/catalog.json.sig"}, "Unexpected publisher changes")
    if not changed:
        print("Catalog is already published; no PR is needed.")
        return
    api(f"repos/{repository}/git/refs", {"ref": "refs/heads/" + branch, "sha": base})
    files = [{"path": name, "contents": base64.b64encode((ROOT / name).read_bytes()).decode()}
             for name in ("Catalog/catalog.json", "Catalog/catalog.json.sig")]
    workflow_url = f"https://github.com/{repository}/actions/runs/{run_id}"
    result = gh("api", "graphql", "--input", "-", data={
        "query": """mutation($input: CreateCommitOnBranchInput!) {
          createCommitOnBranch(input: $input) { commit { oid } }
        }""",
        "variables": {"input": {"branch": {"repositoryNameWithOwner": repository, "branchName": branch},
            "expectedHeadOid": base, "fileChanges": {"additions": files},
            "message": {"headline": "Publish verified Linux image catalog",
                        "body": f"{workflow_url}\n\nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"}}}})
    require(not result.get("errors"), f"Signed catalog commit failed: {result.get('errors')}")
    head = result["data"]["createCommitOnBranch"]["commit"]["oid"]
    require(api(f"repos/{repository}/commits/{head}")["commit"]["verification"]["verified"],
            "GitHub did not verify the catalog commit signature")
    pr = api(f"repos/{repository}/pulls", {"title": "Publish verified Linux image catalog",
             "head": branch, "base": "main", "maintainer_can_modify": False,
             "body": f"Verified image, license and source assets; signed catalog.\n\n{workflow_url}"})
    print(pr["html_url"], flush=True)
    api(f"repos/{repository}/actions/workflows/catalog.yml/dispatches",
        {"ref": branch, "inputs": {"previous": base}})
    deadline = time.monotonic() + 900
    run = None
    while time.monotonic() < deadline:
        path = f"repos/{repository}/actions/workflows/catalog.yml/runs?branch={urllib.parse.quote(branch)}&event=workflow_dispatch&per_page=10"
        runs = api(path)["workflow_runs"]
        matches = [item for item in runs if item["head_sha"] == head]
        if matches:
            run = matches[0]
            if run["status"] == "completed":
                break
        time.sleep(10)
    require(run and run["status"] == "completed" and run["conclusion"] == "success",
            f"Required catalog validation failed or timed out; PR remains open: {pr['html_url']}")
    require(api(f"repos/{repository}/git/ref/heads/main")["object"]["sha"] == base,
            f"Main advanced during checks; rerun publishing. PR remains open: {pr['html_url']}")
    checks = api(f"repos/{repository}/commits/{head}/check-runs?per_page=100")["check_runs"]
    require(any(check["name"] == "Verify the catalog" and check["app"]["id"] == 15368
                and check["status"] == "completed" and check["conclusion"] == "success" for check in checks),
            "The trusted required catalog check is not successful")
    require(all(check["status"] == "completed" and check["conclusion"] in ("success", "neutral", "skipped")
                for check in checks), "Another PR check is pending or failed")
    approved = set()
    result = None
    while time.monotonic() < deadline:
        runs = api(f"repos/{repository}/actions/workflows/catalog.yml/runs?branch={urllib.parse.quote(branch)}&per_page=10")["workflow_runs"]
        pending = False
        for item in runs:
            if (item["head_sha"] != head or item.get("event") != "pull_request"
                    or not any(pull["number"] == pr["number"] for pull in item.get("pull_requests", []))):
                continue
            if item["conclusion"] == "action_required" and item["id"] not in approved:
                require(item["head_branch"] == branch and item["actor"]["login"] == "github-actions[bot]",
                        "Refusing to approve a workflow that is not the generated internal catalog PR")
                print(f"Approving only the signed internal catalog PR workflow {item['id']}.", flush=True)
                api(f"repos/{repository}/actions/runs/{item['id']}/approve", method="POST")
                approved.add(item["id"])
                pending = True
            elif item["status"] != "completed" or item["conclusion"] == "action_required":
                pending = True
            else:
                require(item["conclusion"] == "success", f"Catalog PR workflow failed: {item['html_url']}")
        if pending:
            time.sleep(5)
            continue
        require(api(f"repos/{repository}/git/ref/heads/main")["object"]["sha"] == base,
                "Main advanced during PR validation; rerun publishing")
        try:
            result = api(f"repos/{repository}/pulls/{pr['number']}/merge",
                         {"sha": head, "merge_method": "squash", "commit_title": "Publish verified Linux image catalog",
                          "commit_message": f"{workflow_url}\n\nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"},
                         method="PUT")
            break
        except subprocess.CalledProcessError as error:
            failure = json.loads(error.output)
            message = failure.get("message", "")
            if not (message.startswith("Required status check") and "expected" in message):
                raise
            print("Waiting for the generated PR check and status propagation; protection is not bypassed.", flush=True)
            time.sleep(5)
    require(result is not None, f"Protected catalog merge timed out; PR remains open: {pr['html_url']}")
    require(result["merged"], f"Protected merge rejected: {result['message']}")
    require(api(f"repos/{repository}/commits/{result['sha']}")["commit"]["verification"]["verified"],
            "The merged catalog commit is not signed")
    print(f"Merged {pr['html_url']} through normal branch protection.", flush=True)
    with pathlib.Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
        summary.write(f"\nCatalog merged through protected PR: {pr['html_url']}\n")


if __name__ == "__main__":
    main()
