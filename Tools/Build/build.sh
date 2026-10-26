#!/bin/bash
#
# Builds Runfern for distribution and checks that the result contains exactly what its variant
# needs.
#
#   Tools/Build/build.sh appstore [output]   App Store: QEMU interpreter only. No JIT backend, no
#                                            JIT helper, no VPN, no StikJIT, no VPN entitlement.
#   Tools/Build/build.sh jit [output]        Sideloading: everything, including the JIT backend,
#                                            the JIT helper and VPN extensions, and StikJIT, signed
#                                            for development so a debugger may attach.
#
# The archive and the exported .ipa go to `output` (default: build/<variant>). Needs the vendored
# QEMU frameworks (Tools/QEMU) and, for `jit`, StikJIT (Tools/JIT/build-jit-vendor.sh).

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VARIANT="${1:-}"
OUTPUT="${2:-$REPO/build/$VARIANT}"

case "$VARIANT" in
    appstore) SCHEME="Runfern"; METHOD="app-store-connect" ;;
    jit) SCHEME="Runfern JIT"; METHOD="debugging" ;;
    *) echo "usage: $0 appstore|jit [output]" >&2; exit 64 ;;
esac

fail () { echo "error: $1" >&2; exit 1; }

[ -d "$REPO/Vendor/QEMU/iphoneos" ] || fail "Vendor/QEMU/iphoneos is missing; see Tools/QEMU/README.md."
if [ "$VARIANT" = jit ]; then
    [ -d "$REPO/Vendor/JIT/StikJIT.xcframework" ] || fail "Vendor/JIT/StikJIT.xcframework is missing; run Tools/JIT/build-jit-vendor.sh."
fi

ARCHIVE="$OUTPUT/Runfern.xcarchive"
rm -rf "$ARCHIVE"
mkdir -p "$OUTPUT"

echo "=== Archiving ($SCHEME) ==="
xcodebuild archive -project "$REPO/Runfern.xcodeproj" -scheme "$SCHEME" -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet

APP="$ARCHIVE/Products/Applications/Runfern.app"
[ -d "$APP" ] || fail "The archive contains no Runfern.app."

echo "=== Checking the contents ==="
has () { [ -e "$APP/$1" ]; }
entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
binary="$APP/Runfern"
# Debug builds keep their code in a separate dylib; archives are release builds without it.
[ -f "$APP/Runfern.debug.dylib" ] && binary="$APP/Runfern.debug.dylib"

expect_jit () {
    local wanted="$1" what="$2" present="$3"
    if [ "$wanted" = yes ] && [ "$present" != yes ]; then fail "$what is missing."; fi
    if [ "$wanted" = no ] && [ "$present" = yes ]; then fail "$what must not be part of the App Store build."; fi
}
yes_if () { if "$@"; then echo yes; else echo no; fi; }

wanted=$([ "$VARIANT" = jit ] && echo yes || echo no)
expect_jit "$wanted" "The QEMU JIT backend" "$(yes_if has Frameworks/qemu-aarch64-softmmu-jit.framework)"
expect_jit "$wanted" "StikJIT" "$(yes_if has Frameworks/StikJIT.framework)"
expect_jit "$wanted" "The JIT helper extension" "$(yes_if has PlugIns/RunfernJITHelper.appex)"
expect_jit "$wanted" "The VPN extension" "$(yes_if has PlugIns/RunfernTunnel.appex)"
expect_jit "$wanted" "The VPN entitlement" "$(yes_if grep -q networkextension <<< "$entitlements")"
expect_jit "$wanted" "The JIT code" "$(yes_if grep -q cancelExtensionRequestWithIdentifier "$binary")"
has Frameworks/qemu-aarch64-softmmu.framework || fail "The QEMU interpreter is missing."
echo "Contents match the $VARIANT variant."

echo "=== Exporting ==="
TEAM="$(xcodebuild -project "$REPO/Runfern.xcodeproj" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | awk '$1 == "DEVELOPMENT_TEAM" { print $3; exit }')"
OPTIONS="$OUTPUT/ExportOptions.plist"
cat > "$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$METHOD</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUTPUT" -exportOptionsPlist "$OPTIONS" \
    -allowProvisioningUpdates -quiet
echo "Done: $(ls "$OUTPUT"/*.ipa)"
