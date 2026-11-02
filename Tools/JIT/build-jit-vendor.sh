#!/bin/bash
#
# Fetches what Runfern's built-in JIT needs and places it in Vendor/JIT/. Both are pinned releases
# whose checksums are verified:
#
#   StikJIT.xcframework   the debugger half (MPL-2.0), which the JIT helper extension runs
#   IDevice.xcframework   idevice's C library (MIT), with which Runfern creates the pairing file
#                         on the iPad itself; only its iPadOS slice, linked statically into
#                         Debug and Sideload builds (Runfern.xcodeproj: LIBRARY_SEARCH_PATHS,
#                         SWIFT_INCLUDE_PATHS). Without it, those builds simply lack that option.
#
# Usage: Tools/JIT/build-jit-vendor.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/Vendor/JIT"
STIKJIT_VERSION="2.0.1"
STIKJIT_SHA256="c376687326a785f5ed1da8caca08adc709b56919019dd751bca059b92b175d95"
IDEVICE_VERSION="v0.1.68"
IDEVICE_COMMIT="d32c8189c51c2789496b0768039419c3705498c3"
IDEVICE_SHA256="c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"
IDEVICE_LICENSE_SHA256="131488ce7e302b9f62e3236793e57c86a208d3dfaf03e6d7d03ddc0fc82392ed"

fail () { echo "error: $1" >&2; exit 1; }

mkdir -p "$TARGET"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "=== Fetching StikJIT $STIKJIT_VERSION ==="
curl -sSfL -o "$work/StikJIT.xcframework.zip" \
    "https://github.com/StikDebug/StikJIT/releases/download/$STIKJIT_VERSION/StikJIT.xcframework.zip"
echo "$STIKJIT_SHA256  $work/StikJIT.xcframework.zip" | shasum -a 256 -c -
mkdir "$work/stikjit"
unzip -q "$work/StikJIT.xcframework.zip" -d "$work/stikjit"
framework="$work/stikjit/StikJIT.xcframework/ios-arm64/StikJIT.framework"
for file in Info.plist StikJIT legacy.js; do
    [ -s "$framework/$file" ] || fail "StikJIT $STIKJIT_VERSION lacks $file."
done
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$framework/Info.plist" 2>/dev/null \
    || plutil -extract CFBundleShortVersionString raw "$framework/Info.plist")"
[ "$version" = "$STIKJIT_VERSION" ] || fail "StikJIT reports version $version instead of $STIKJIT_VERSION."
rm -rf "$TARGET/StikJIT.xcframework"
mv "$work/stikjit/StikJIT.xcframework" "$TARGET/"

echo "=== Fetching idevice $IDEVICE_VERSION (about 210 MB) ==="
curl -sSfL -o "$work/idevice.zip" \
    "https://github.com/jkcoxson/idevice/releases/download/$IDEVICE_VERSION/idevice-xcframework-$IDEVICE_VERSION.zip"
echo "$IDEVICE_SHA256  $work/idevice.zip" | shasum -a 256 -c -
mkdir "$work/idevice"
# Only the iPadOS slice; the archive keeps everything under swift/.
unzip -q "$work/idevice.zip" 'swift/IDevice.xcframework/Info.plist' 'swift/IDevice.xcframework/ios-arm64/*' -d "$work/idevice"
slice="$work/idevice/swift/IDevice.xcframework/ios-arm64"
[ -s "$slice/libidevice_ffi.a" ] || fail "idevice $IDEVICE_VERSION lacks ios-arm64/libidevice_ffi.a."
[ -s "$slice/Headers/idevice.h" ] || fail "idevice $IDEVICE_VERSION lacks ios-arm64/Headers/idevice.h."
# `import IDevice` links the library by itself, so builds without Vendor/JIT need no linker flags.
cat > "$slice/Headers/module.modulemap" <<'EOF'
module IDevice {
    header "idevice.h"
    link "idevice_ffi"
    link framework "CoreFoundation"
    link framework "Security"
    export *
}
EOF
# The release carries no license file; take it from the tagged source.
curl -sSfL -o "$work/idevice/swift/IDevice.xcframework/LICENSE.txt" \
    "https://raw.githubusercontent.com/jkcoxson/idevice/$IDEVICE_COMMIT/LICENSE.txt"
echo "$IDEVICE_LICENSE_SHA256  $work/idevice/swift/IDevice.xcframework/LICENSE.txt" | shasum -a 256 -c -
rm -rf "$TARGET/IDevice.xcframework"
mv "$work/idevice/swift/IDevice.xcframework" "$TARGET/"

echo "Installed into $TARGET:"
du -sh "$TARGET"/*.xcframework
