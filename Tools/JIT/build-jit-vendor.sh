#!/bin/bash
#
# Fetches what Runfern's built-in JIT needs and places it in Vendor/JIT/:
#
#   StikJIT.xcframework     the debugger half (MPL-2.0), pinned release, checksum verified
#
# Usage: Tools/JIT/build-jit-vendor.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/Vendor/JIT"
STIKJIT_VERSION="1.9.0"
STIKJIT_SHA256="806664393770c68e75f2b6429955bfdd88cfaad09fec2ba70f8ed615ff90c060"

mkdir -p "$TARGET"

echo "=== Fetching StikJIT $STIKJIT_VERSION ==="
archive="$(mktemp -d)/StikJIT.xcframework.zip"
curl -sSfL -o "$archive" "https://github.com/StikDebug/StikJIT/releases/download/$STIKJIT_VERSION/StikJIT.xcframework.zip"
echo "$STIKJIT_SHA256  $archive" | shasum -a 256 -c -
rm -rf "$TARGET/StikJIT.xcframework"
unzip -q "$archive" -d "$TARGET"

echo "Installed into $TARGET:"
du -sh "$TARGET"/*
