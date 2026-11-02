#!/bin/bash
#
# Publishes a built Linux base (Tools/GuestImage/build/<id>/<id>.runfernimage) as a release asset
# of the Runfern repository and enters it in Catalog/catalog.json: address, checksum, size, and the
# image's catalogVersion. Runs on a Mac or on Linux, by hand or in the "Publish Linux Base" workflow.
#
# Every build is a release of its own, named after the image and its catalogVersion (for example
# debian-12-arm64-v4), and published builds are never replaced. The catalog lists only the newest
# build of each base, though, so environments created on an earlier build can't download it again:
# a new build of a published base therefore needs --rebuild, and gets the next version. A build the
# catalog lists already is left alone, so running this again changes nothing.
#
# Afterwards raise the catalog's version (catalog_release.py finish), sign it (sign-catalog.sh),
# commit, and push; the workflow does that itself.
#
# Usage: Tools/Catalog/publish-image.sh [--rebuild] <image id>
#        needs the GitHub CLI (brew install gh; gh auth login), or GH_TOKEN in GitHub Actions

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
BUILD="$ROOT/Tools/GuestImage/build/$IMAGE"
ARCHIVE="$BUILD/$IMAGE.runfernimage"
ASSET="$IMAGE.runfernimage"
# GitHub accepts release assets below 2 GiB.
ASSET_LIMIT=2147483648

fail() { echo "error: $*" >&2; exit 1; }
catalog_release() { python3 "$HERE/catalog_release.py" "$@"; }

[ -f "$ARCHIVE" ] || fail "$ARCHIVE is missing; build it with Tools/GuestImage/build_image.py $IMAGE."
command -v gh >/dev/null || fail "the GitHub CLI is missing: brew install gh; gh auth login"

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

# Unknown ids fail here, before anything is uploaded.
PUBLISHED="$(catalog_release published-version "$IMAGE" "$SHA256")"
if [ -n "$PUBLISHED" ]; then
    # For example the workflow run again after it pushed its catalog: no second release, no new version.
    echo "$IMAGE: Catalog/catalog.json lists this build already (image version $PUBLISHED); nothing to do."
    exit 0
fi
# A published base stops here without --rebuild.
VERSION="$(catalog_release next-version ${REBUILD[@]+"${REBUILD[@]}"} "$IMAGE")"
TAG="$IMAGE-v$VERSION"
URL="https://github.com/$REPOSITORY/releases/download/$TAG/$ASSET"

# Release $TAG as "<draft> <notes name the checksum> <asset state> <asset size> <asset digest>",
# the asset's fields only if it has the image; fails without the release (gh finds drafts too).
release_state() {
    gh release view "$TAG" --repo "$REPOSITORY" --json isDraft,body,assets --jq "[.isDraft, (.body // \"\" | contains(\"$SHA256\"))]
        + [.assets[] | select(.name == \"$ASSET\") | .state, .size, (.digest // \"-\")] | map(tostring) | join(\" \")"
}

# Whether a release state shows this very build, completely uploaded. GitHub reports the asset's
# digest itself; older versions of gh don't pass it on ("-"), and then the size has to do.
holds_this_build() {
    local noted state size digest
    read -r _ noted state size digest <<< "$1"
    [ "$noted" = true ] && [ "$state" = uploaded ] && [ "$size" = "$SIZE" ] \
        && { [ "$digest" = - ] || [ "$digest" = "sha256:$SHA256" ]; }
}

if STATE="$(release_state 2>/dev/null)"; then
    # The catalog doesn't list this release yet. If it holds this very build, an earlier publish
    # stopped before its catalog was pushed, and publishing continues with it.
    holds_this_build "$STATE" || fail "release $TAG exists already and holds another build or an incomplete upload.
Published builds are never replaced. Is Catalog/catalog.json up to date (git pull)? If the catalog
on main doesn't list $TAG, it is left from a publish that stopped halfway: delete it
(gh release delete $TAG --cleanup-tag --repo $REPOSITORY) and run this again."
    if [ "${STATE%% *}" = true ]; then
        # gh release create uploads to a draft and publishes it last, so a publish stopped in
        # between leaves a draft, which has no public download address yet.
        echo "Release $TAG is a draft with this build; publishing it."
        gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest=false
    else
        echo "Release $TAG holds this build already; entering it in the catalog."
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
fi
# Only a published release with the complete build goes into the catalog.
STATE="$(release_state)" || fail "release $TAG can't be read after publishing."
holds_this_build "$STATE" && [ "${STATE%% *}" = false ] \
    || fail "release $TAG doesn't hold $ASSET, published, with $SIZE bytes and SHA-256 $SHA256 after the upload."

catalog_release set-source "$IMAGE" "$VERSION" "$URL" "$SHA256" "$SIZE"
echo "$IMAGE: image version $VERSION, $SIZE bytes, $URL"
echo "Next: Tools/Catalog/catalog_release.py finish, Tools/Catalog/sign-catalog.sh, then commit Catalog/ and push."
