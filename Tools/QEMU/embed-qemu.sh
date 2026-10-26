#!/bin/bash
#
# Xcode build phase "Embed QEMU": copies the vendored QEMU frameworks for the current SDK into
# the app and signs them. Without vendored frameworks the app builds with the simulated runtime.
# Only builds with RUNFERN_JIT = YES (Debug, Sideload) also get the JIT parts: the JIT variant of
# QEMU, StikJIT (Vendor/JIT, see Tools/JIT/build-jit-vendor.sh), which the JIT helper loads from
# the app's Frameworks folder, and the JIT helper and VPN extensions. The extensions are built
# with every configuration but copied into the app only here, so App Store builds never contain
# them.

set -euo pipefail

SOURCE="$SRCROOT/Vendor/QEMU/$PLATFORM_NAME"
TARGET="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"

sign () {
    if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,entitlements,flags \
            --timestamp=none "$1"
    fi
}

PLUGINS="$TARGET_BUILD_DIR/$PLUGINS_FOLDER_PATH"
if [ "${RUNFERN_JIT:-NO}" != "YES" ]; then
    rm -rf "$PLUGINS/RunfernJITHelper.appex" "$PLUGINS/RunfernTunnel.appex" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/StikJIT.framework"
else
    # Built (and signed) by their own targets, which the app depends on.
    mkdir -p "$PLUGINS"
    for extension in RunfernJITHelper RunfernTunnel; do
        rsync -aL --delete "$BUILT_PRODUCTS_DIR/$extension.appex/" "$PLUGINS/$extension.appex/"
    done
fi
if [ "${RUNFERN_JIT:-NO}" = "YES" ] && [ "$PLATFORM_NAME" = "iphoneos" ] \
    && [ -d "$SRCROOT/Vendor/JIT/StikJIT.xcframework/ios-arm64/StikJIT.framework" ]; then
    mkdir -p "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
    stikjit="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/StikJIT.framework"
    rsync -a --delete --exclude Headers --exclude Modules \
        "$SRCROOT/Vendor/JIT/StikJIT.xcframework/ios-arm64/StikJIT.framework/" "$stikjit/"
    # The release ships without the Info.plist that iPadOS requires of embedded frameworks.
    if [ ! -f "$stikjit/Info.plist" ]; then
        plutil -create xml1 "$stikjit/Info.plist"
        plutil -insert CFBundleExecutable -string StikJIT "$stikjit/Info.plist"
        plutil -insert CFBundleIdentifier -string "$PRODUCT_BUNDLE_IDENTIFIER.StikJIT" "$stikjit/Info.plist"
        plutil -insert CFBundleName -string StikJIT "$stikjit/Info.plist"
        plutil -insert CFBundlePackageType -string FMWK "$stikjit/Info.plist"
        plutil -insert CFBundleShortVersionString -string 1.9.0 "$stikjit/Info.plist"
        plutil -insert CFBundleVersion -string 1 "$stikjit/Info.plist"
        plutil -insert MinimumOSVersion -string 17.4 "$stikjit/Info.plist"
    fi
    sign "$stikjit"
fi

if [ ! -d "$SOURCE" ]; then
    echo "note: No QEMU frameworks in $SOURCE; building with the simulated runtime."
    exit 0
fi

mkdir -p "$TARGET"
for framework in "$SOURCE"/*.framework; do
    name="$(basename "$framework")"
    # The JIT backend ships only in builds for sideloading; App Store builds interpret.
    case "$name" in
        *-jit.framework)
            if [ "${RUNFERN_JIT:-NO}" != "YES" ]; then
                rm -rf "$TARGET/$name"
                continue
            fi ;;
    esac
    rsync -a --delete "$framework/" "$TARGET/$name/"
    sign "$TARGET/$name"
done
