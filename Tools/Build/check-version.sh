#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG="${1:?usage: check-version.sh v<major>.<minor>.<patch>}"
VERSION="$(sed -n 's/^MARKETING_VERSION = //p' "$ROOT/Version.xcconfig")"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: not an app release tag: $TAG" >&2; exit 1; }
[ "$TAG" = "v$VERSION" ] || { echo "error: $TAG does not match Version.xcconfig ($VERSION)." >&2; exit 1; }
if grep -q 'MARKETING_VERSION =' "$ROOT/Runfern.xcodeproj/project.pbxproj"; then
    echo "error: targets must inherit MARKETING_VERSION from Version.xcconfig." >&2
    exit 1
fi
echo "Release tag and app version match: $TAG."
