#!/bin/bash
#
# Builds Runfern for distribution and checks that the result contains exactly what its variant
# needs.
#
#   Tools/Build/build.sh appstore-archive [output]  Signed archive only; no upload or export.
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
    appstore-archive) SCHEME="Runfern"; METHOD="" ;;
    jit) SCHEME="Runfern JIT"; METHOD="debugging" ;;
    *) echo "usage: $0 appstore-archive|appstore|jit [output]" >&2; exit 64 ;;
esac

fail () { echo "error: $1" >&2; exit 1; }

python3 "$REPO/Tools/Licenses/verify.py" --notices-only
case "${RUNFERN_INTERNAL_BUILD:-0}" in
    1) echo "warning: private validation build only; this does not grant release approval." >&2 ;;
    0)
        python3 "$REPO/Tools/Licenses/verify.py" --notices-only --require-clearance
        ;;
    *) fail "RUNFERN_INTERNAL_BUILD must be 0 or 1." ;;
esac

AUTH=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
    [ -s "$ASC_KEY_PATH" ] || fail "ASC_KEY_PATH does not contain an App Store Connect API key."
    AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "${ASC_KEY_ID:?}" -authenticationKeyIssuerID "${ASC_ISSUER_ID:?}")
fi
if [ -n "${RUNFERN_RELEASE_TAG:-}" ]; then
    "$REPO/Tools/Build/check-version.sh" "$RUNFERN_RELEASE_TAG"
fi
[ -d "$REPO/Vendor/QEMU/iphoneos" ] || fail "Vendor/QEMU/iphoneos is missing; see Tools/QEMU/README.md."
if [ "$VARIANT" = jit ]; then
    [ -d "$REPO/Vendor/JIT/StikJIT.xcframework" ] || fail "Vendor/JIT/StikJIT.xcframework is missing; run Tools/JIT/build-jit-vendor.sh."
    [ -d "$REPO/Vendor/JIT/IDevice.xcframework" ] \
        || echo "warning: Vendor/JIT/IDevice.xcframework is missing; this build cannot create pairing files on the iPad." >&2
fi

ARCHIVE="$OUTPUT/Runfern.xcarchive"
[ ! -e "$ARCHIVE" ] || fail "$ARCHIVE exists already; choose a new output directory."
mkdir -p "$OUTPUT"

echo "=== Archiving ($SCHEME) ==="
xcodebuild archive -project "$REPO/Runfern.xcodeproj" -scheme "$SCHEME" -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" -derivedDataPath "$OUTPUT/DerivedData" -allowProvisioningUpdates \
    ${AUTH[@]+"${AUTH[@]}"} -quiet

APP="$ARCHIVE/Products/Applications/Runfern.app"
[ -d "$APP" ] || fail "The archive contains no Runfern.app."

echo "=== Checking the contents ==="
has () { [ -e "$APP/$1" ]; }
codesign --verify --deep --strict "$APP"
entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" || fail "The app's signing entitlements cannot be read."
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
plist_value () { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }
info="$APP/Info.plist"
version="$(sed -n 's/^MARKETING_VERSION = //p' "$REPO/Version.xcconfig")"
[ "$(plist_value "$info" CFBundleShortVersionString)" = "$version" ] || fail "The archive has the wrong release version."
expect_jit "$wanted" "Local Network access for pairing" "$(yes_if [ -n "$(plist_value "$info" NSLocalNetworkUsageDescription)" ])"
expect_jit "$wanted" "The pairable host Bonjour type" "$(yes_if [ -n "$(plist_value "$info" NSBonjourServices.0)" ])"
[ -n "$(plist_value "$info" BGTaskSchedulerPermittedIdentifiers.0)" ] || fail "BGTaskSchedulerPermittedIdentifiers is missing."
if [ "$VARIANT" = jit ]; then
    [ "$(plist_value "$APP/Frameworks/StikJIT.framework/Info.plist" CFBundleShortVersionString)" = 2.0.1 ] \
        || fail "StikJIT is not version 2.0.1."
    otool -L "$APP/PlugIns/RunfernJITHelper.appex/RunfernJITHelper" | grep -q "@rpath/StikJIT.framework/StikJIT" \
        || fail "The JIT helper does not load StikJIT."
    [ "$(plist_value "$APP/PlugIns/RunfernJITHelper.appex/Info.plist" NSExtension.NSExtensionContextClass)" = NSExtensionContext ] \
        || fail "The JIT helper's Info.plist lacks NSExtensionContextClass."
    jit_qemu="$APP/Frameworks/qemu-aarch64-softmmu-jit.framework/qemu-aarch64-softmmu-jit"
    perl -0777 -ne 'my $at = -1; while (($at = index($_, "\x20\x0d\x20\xd4", $at + 1)) >= 0) { exit 0 if $at % 4 == 0 } exit 1' \
        "$jit_qemu" || fail "The JIT QEMU lacks the handshake with the debugger (brk #0x69); build it from UTM 5.0.4 or later."
    if [ -d "$REPO/Vendor/JIT/IDevice.xcframework" ]; then
        grep -q "_remotepairing-pairable-host" "$binary" || fail "The pairing code is missing although idevice is vendored."
    fi
fi
echo "Contents match the $VARIANT variant."

license_flavor=$([ "$VARIANT" = jit ] && echo jit || echo no-jit)
license_arguments=()
if [ "${RUNFERN_INTERNAL_BUILD:-0}" != 1 ]; then license_arguments=(--release); fi
python3 "$REPO/Tools/Licenses/verify.py" --app "$APP" --flavor "$license_flavor" \
    ${license_arguments[@]+"${license_arguments[@]}"}

[ -n "$METHOD" ] || { echo "Done: signed archive $ARCHIVE (no upload)."; exit 0; }

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
    -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} -quiet
echo "Done: $(ls "$OUTPUT"/*.ipa)"
