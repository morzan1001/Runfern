#!/bin/bash
#
# Publishes a built Linux base (Tools/GuestImage/build/<id>/<id>.runfernimage) as a release asset
# of the Runfern repository and enters its address, checksum, and size in Catalog/catalog.json.
# Sign the catalog afterwards (sign-catalog.sh) and push it.
#
# The release is named after the image and its catalogVersion (for example debian-12-arm64-v4),
# so every published build stays downloadable for environments created from it.
#
# Usage: Tools/Catalog/publish-image.sh <image id>     needs the GitHub CLI: brew install gh; gh auth login

set -euo pipefail

REPOSITORY="morzan1001/Runfern"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
IMAGE="${1:?usage: $0 <image id>}"
ARCHIVE="$ROOT/Tools/GuestImage/build/$IMAGE/$IMAGE.runfernimage"
CATALOG="$ROOT/Catalog/catalog.json"

[ -f "$ARCHIVE" ] || { echo "error: $ARCHIVE is missing; build it with Tools/GuestImage/build_image.py." >&2; exit 1; }
command -v gh >/dev/null || { echo "error: the GitHub CLI is missing: brew install gh; gh auth login" >&2; exit 1; }

VERSION="$(python3 -c "import json,sys; print(next(i['catalogVersion'] for i in json.load(open(sys.argv[1]))['baseImages'] if i['id'] == sys.argv[2]))" "$CATALOG" "$IMAGE")"
TAG="$IMAGE-v$VERSION"
SHA256="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
SIZE="$(stat -f %z "$ARCHIVE")"

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    echo "error: release $TAG exists already. Published builds are never replaced; raise the image's catalogVersion." >&2
    exit 1
fi
gh release create "$TAG" "$ARCHIVE" --repo "$REPOSITORY" --title "$TAG" \
    --notes "Linux base $IMAGE, catalog version $VERSION. SHA-256: $SHA256"

python3 - "$CATALOG" "$IMAGE" "https://github.com/$REPOSITORY/releases/download/$TAG/$IMAGE.runfernimage" "$SHA256" "$SIZE" <<'PYTHON'
import json, sys
path, image_id, url, sha256, size = sys.argv[1:]
catalog = json.load(open(path))
image = next(i for i in catalog["baseImages"] if i["id"] == image_id)
image["source"] = {"url": url, "sha256": sha256}
image["downloadSizeBytes"] = int(size)
with open(path, "w") as handle:
    json.dump(catalog, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
print(f"{image_id}: {url}")
PYTHON
echo "Next: raise catalogVersion in Catalog/catalog.json if needed, then Tools/Catalog/sign-catalog.sh, commit, and push."
