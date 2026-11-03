#!/usr/bin/env python3
"""Reuse only verified image artifacts from protected-main publishing workflows."""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/GuestImage"))
import image_evidence


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True, cwd=ROOT))


def select(run_id, image):
    repository = os.environ["GITHUB_REPOSITORY"]
    require(repository == "morzan1001/Runfern" and os.environ["GITHUB_REF"] == "refs/heads/main",
            "Image reuse is restricted to the protected main publisher")
    require(run_id.isdigit() and run_id != os.environ["GITHUB_RUN_ID"], "Invalid source workflow run")
    require(re.fullmatch(r"[a-z0-9][a-z0-9.-]*", image), "Invalid image identity")
    run = api(f"repos/{repository}/actions/runs/{run_id}")
    require(run["path"] == ".github/workflows/publish-linux-base.yml"
            and run["event"] == "workflow_dispatch" and run["head_branch"] == "main"
            and run["head_repository"]["full_name"] == repository,
            "Source artifacts must come from this repository's main image publisher")
    source = run["head_sha"]
    require(api(f"repos/{repository}/commits/{source}")["commit"]["verification"]["verified"],
            "The source workflow commit is not signed")
    current = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True, cwd=ROOT).strip()
    require(api(f"repos/{repository}/compare/{source}...{current}")["status"] in ("ahead", "identical"),
            "The source workflow commit is not an ancestor of the current protected publisher")
    jobs = api(f"repos/{repository}/actions/runs/{run_id}/jobs?per_page=100")["jobs"]
    matches = [job for job in jobs if job["name"] == "Build " + image]
    require(len(matches) == 1 and matches[0]["status"] == "completed",
            "The source image build is missing, ambiguous or still running")
    if matches[0]["conclusion"] != "success":
        require(matches[0]["conclusion"] in ("failure", "cancelled", "timed_out"),
                "The source image did not complete an actual build")
        return source, False
    artifacts = api(f"repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100")["artifacts"]
    matches = [artifact for artifact in artifacts if artifact["name"] == "image-" + image]
    require(len(matches) == 1 and not matches[0]["expired"]
            and re.fullmatch(r"sha256:[0-9a-f]{64}", matches[0].get("digest", "")),
            "The successful image artifact is missing, expired or has no digest")
    return source, True


def verify(run_id, image, build_root):
    source, reusable = select(run_id, image)
    require(reusable, "A failed image build cannot be reused")
    manifest = image_evidence.verify(build_root / image, image, publication=True)
    require(manifest["sourceRevision"]["commit"] == source,
            "Image evidence does not belong to the verified source workflow commit")
    print(f"Verified unchanged {image} artifact from protected source run {run_id}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--build-root", type=pathlib.Path,
                        default=ROOT / "Tools/GuestImage/build")
    args = parser.parse_args()
    if args.verify:
        verify(args.run, args.image, args.build_root)
    else:
        _, reusable = select(args.run, args.image)
        with pathlib.Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"reuse={'true' if reusable else 'false'}\n")
        print(f"{args.image}: {'reuse the successful artifact' if reusable else 'build the failed image again'}.")


if __name__ == "__main__":
    main()
