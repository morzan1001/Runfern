#!/bin/bash
#
# Publishes a built Linux base (Tools/GuestImage/build/<id>/<id>.runfernimage) as a release asset
# of the Runfern repository and enters it in Catalog/catalog.json: address, checksum, size, and the
# image's catalogVersion. Runs on a Mac or on Linux, by hand or in the "Publish Linux Base" workflow.
#
# Every build is a release of its own, named after the image and its catalogVersion (for example
# debian-12-arm64-v4). A new build of a published base gets the next version; published builds are
# never replaced, so environments created from an older build can still download it.
#
# Afterwards raise the catalog's version (catalog_release.py finish), sign it (sign-catalog.sh),
# commit, and push; the workflow does that itself.
#
# Usage: Tools/Catalog/publish-image.sh <image id>
#        needs the GitHub CLI (brew install gh; gh auth login), or GH_TOKEN in GitHub Actions

set -euo pipefail

REPOSITORY="morzan1001/Runfern"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMAGE="${1:?usage: $0 <image id>}"
BUILD="$ROOT/Tools/GuestImage/build/$IMAGE"
ARCHIVE="$BUILD/$IMAGE.runfernimage"
ASSET="$IMAGE.runfernimage"
# GitHub accepts release assets below 2 GiB.
ASSET_LIMIT=2147483648

fail() { echo "error: $*" >&2; exit 1; }
catalog_release() { python3 "$HERE/catalog_release.py" "$@"; }

[ -f "$ARCHIVE" ] || fail "$ARCHIVE is missing; build it with Tools/GuestImage/build_image.py $IMAGE."
command -v gh >/dev/null || fail "the GitHub CLI is missing: brew install gh; gh auth login"

# Unknown ids fail here, before anything is uploaded.
VERSION="$(catalog_release next-version "$IMAGE")"
TAG="$IMAGE-v$VERSION"
URL="https://github.com/$REPOSITORY/releases/download/$TAG/$ASSET"

SIZE="$(wc -c < "$ARCHIVE" | tr -d ' ')"
[ "$SIZE" -lt "$ASSET_LIMIT" ] || fail "$ARCHIVE has $SIZE bytes; GitHub release assets must stay below 2 GiB."
if command -v sha256sum >/dev/null; then
    SHA256="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
else
    SHA256="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
fi
# The checksum the build wrote catches an archive damaged on its way here, for example between
# the workflow's build and publish jobs.
if [ -f "$BUILD/$IMAGE.sha256" ] && [ "$(tr -d '[:space:]' < "$BUILD/$IMAGE.sha256")" != "$SHA256" ]; then
    fail "$ARCHIVE doesn't match the checksum in $BUILD/$IMAGE.sha256."
fi

# Size of the image in release $TAG; empty without one.
asset_size() {
    gh release view "$TAG" --repo "$REPOSITORY" --json assets \
        --jq ".assets[] | select(.name == \"$ASSET\") | .size" 2>/dev/null || true
}

if NOTES="$(gh release view "$TAG" --repo "$REPOSITORY" --json body --jq .body 2>/dev/null)"; then
    # The catalog doesn't list this release yet. If it holds this very build, an earlier publish
    # stopped before its catalog was pushed, and publishing continues with it.
    if [[ "$NOTES" == *"$SHA256"* ]] && [ "$(asset_size)" = "$SIZE" ]; then
        echo "Release $TAG holds this build already; entering it in the catalog."
    else
        fail "release $TAG exists already and holds another build. Published builds are never replaced.
Is Catalog/catalog.json up to date (git pull)? If no catalog on GitHub lists $TAG, it is left
from a publish that stopped halfway: delete it (gh release delete $TAG --cleanup-tag --repo $REPOSITORY)
and run this again."
    fi
else
    # In the workflow the tag marks the commit the image was built from.
    TARGET=()
    if [ -n "${GITHUB_SHA:-}" ]; then
        TARGET=(--target "$GITHUB_SHA")
    fi
    # Not "Latest": that stays for app releases. ${TARGET[@]+...} keeps the Mac's Bash 3.2 happy.
    gh release create "$TAG" "$ARCHIVE" --repo "$REPOSITORY" --title "$TAG" --latest=false \
        ${TARGET[@]+"${TARGET[@]}"} \
        --notes "Linux base $IMAGE, image catalog version $VERSION ($SIZE bytes). SHA-256: $SHA256"
    [ "$(asset_size)" = "$SIZE" ] || fail "release $TAG doesn't hold $ASSET with $SIZE bytes after the upload."
fi

catalog_release set-source "$IMAGE" "$VERSION" "$URL" "$SHA256" "$SIZE"
echo "$IMAGE: image version $VERSION, $SIZE bytes, $URL"
echo "Next: Tools/Catalog/catalog_release.py finish, Tools/Catalog/sign-catalog.sh, then commit Catalog/ and push."
