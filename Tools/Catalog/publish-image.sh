#!/bin/bash
# Upload a smoke-tested Linux image with its exact legal and source companions to the draft release
# of the next catalog version (catalog-v<N>). Publish that release once every image of the run is in
# it (the "Publish Linux images" workflow does), then sign and submit the catalog.
set -euo pipefail

REPOSITORY="morzan1001/Runfern"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REBUILD=()
if [ "${1:-}" = --rebuild ]; then
    REBUILD=(--rebuild)
    shift
fi
IMAGE="${1:?usage: $0 [--rebuild] <image id>}"
BUILD_ROOT="${RUNFERN_IMAGE_BUILD_ROOT:-$ROOT/Tools/GuestImage/build}"
BUILD="$BUILD_ROOT/$IMAGE"
ARCHIVE="$BUILD/$IMAGE.runfernimage"
fail() { echo "error: $*" >&2; exit 1; }
catalog_release() { python3 "$HERE/catalog_release.py" "$@"; }
command -v gh >/dev/null || fail "GitHub CLI is missing; install gh and authenticate."
python3 "$ROOT/Tools/GuestImage/image_evidence.py" verify "$IMAGE" --build-root "$BUILD_ROOT" --publication
SHA256="$(tr -d '[:space:]' < "$BUILD/$IMAGE.sha256")"

PYTHONPATH="$ROOT/Tools/GuestImage" python3 - "$BUILD" "$IMAGE" "$SHA256" <<'PYTHON'
import json, pathlib, sys
from image_evidence import digest, require, write_json
build, image, expected = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
manifest = json.loads((build / f"{image}.evidence.json").read_text())
require(expected == manifest["imageSHA256"], "Build checksum differs from evidence")
assets = dict(manifest["assets"])
assets.update({f"{image}.runfernimage": expected})
for extension in ("evidence.json", "sha256", "json"):
    path = build / f"{image}.{extension}"
    assets[path.name] = digest(path)
write_json(build / "publication-assets.json", {
    name: {"sha256": value, "size": (build / name).stat().st_size} for name, value in assets.items()})
PYTHON

PUBLISHED="$(catalog_release published-version "$IMAGE" "$SHA256")"
if [ -n "$PUBLISHED" ]; then
    echo "$IMAGE: this build is already in the catalog (image version $PUBLISHED)."
    exit 0
fi
VERSION="$(catalog_release next-version ${REBUILD[@]+"${REBUILD[@]}"} "$IMAGE")"
TAG="$(catalog_release release-tag)"
URL="https://github.com/$REPOSITORY/releases/download/$TAG/$IMAGE.runfernimage"

release_state() {
    gh release view "$TAG" --repo "$REPOSITORY" --json isDraft,body,assets > "$BUILD/release-state.json"
}

verify_remote() {
    python3 - "$BUILD" "$IMAGE" "$SHA256" "${1:-complete}" <<'PYTHON'
import json, pathlib, sys
build, image, checksum, mode = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
state = json.loads((build / "release-state.json").read_text())
expected = json.loads((build / "publication-assets.json").read_text())
# The release holds every image of its catalog version; this image's assets start with its id.
actual = {asset["name"]: asset for asset in state["assets"] if asset["name"].startswith(image + ".")}
for name, asset in actual.items():
    if name not in expected:
        raise SystemExit(f"Unexpected release asset: {name}")
    item = expected[name]
    if asset["state"] != "uploaded" or asset["size"] != item["size"] or asset.get("digest") != "sha256:" + item["sha256"]:
        raise SystemExit(f"Release asset is incomplete or differs: {name}; inspect the draft before retrying.")
missing = sorted(set(expected) - set(actual))
if mode == "missing" and state["isDraft"]:
    print("\n".join(missing))
elif missing:
    raise SystemExit("Release is missing source/legal/image assets: " + ", ".join(missing))
PYTHON
}

EXISTING="$(gh api "repos/$REPOSITORY/releases?per_page=100" --paginate --jq ".[] | select(.tag_name == \"$TAG\") | .tag_name")"
if [ -z "$EXISTING" ]; then
    TARGET="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
    gh release create "$TAG" --repo "$REPOSITORY" --draft --target "$TARGET" --latest=false \
        --title "Linux images – catalog v${TAG#catalog-v}" \
        --notes "ARM64 Linux images with OpenVSCode Server for Runfern catalog version ${TAG#catalog-v}. Each image comes with its checksum, build evidence, license texts and exact source inputs."
fi
release_state

MISSING="$(verify_remote missing)"
if [ -n "$MISSING" ]; then
    while IFS= read -r name; do
        gh release upload "$TAG" "$BUILD/$name" --repo "$REPOSITORY"
    done <<< "$MISSING"
fi
release_state
verify_remote
SIZE="$(wc -c < "$ARCHIVE" | tr -d ' ')"
catalog_release set-source "$IMAGE" "$VERSION" "$URL" "$SHA256" "$SIZE"
echo "$IMAGE: image version $VERSION, $SIZE bytes, $URL"
echo "Publish $TAG once it holds every image of the run, then finish, sign and submit the catalog."
