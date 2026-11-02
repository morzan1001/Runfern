#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHIVE="${1:?usage: package-sideload.sh <signed xcarchive> <output.ipa>}"
OUTPUT="${2:?usage: package-sideload.sh <signed xcarchive> <output.ipa>}"
SOURCE="$ARCHIVE/Products/Applications/Runfern.app"
[ -d "$SOURCE" ] || { echo "error: the archive has no Runfern.app." >&2; exit 1; }
[ ! -e "$OUTPUT" ] || { echo "error: $OUTPUT exists already." >&2; exit 1; }
codesign --verify --deep --strict "$SOURCE"
license_arguments=()
case "${RUNFERN_INTERNAL_BUILD:-0}" in
    0) license_arguments=(--release) ;;
    1) echo "warning: private packaging test only; this does not grant release approval." >&2 ;;
    *) echo "error: RUNFERN_INTERNAL_BUILD must be 0 or 1." >&2; exit 1 ;;
esac
python3 "$ROOT/Tools/Licenses/verify.py" --app "$SOURCE" --flavor jit \
    ${license_arguments[@]+"${license_arguments[@]}"}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Payload/Runfern.app"
mkdir -p "$WORK/Payload" "$(dirname "$OUTPUT")"
ditto "$SOURCE" "$APP"

while IFS= read -r -d '' profile; do
    rm "$profile"
done < <(find "$APP" -name embedded.mobileprovision -type f -print0)
while IFS= read -r -d '' bundle; do
    codesign --remove-signature "$bundle"
done < <(find "$APP" -depth \( -name '*.framework' -o -name '*.appex' -o -name '*.app' \) -type d -print0)
while IFS= read -r -d '' signature; do
    rmdir "$signature"
done < <(find "$APP" -depth -name _CodeSignature -type d -print0)
if codesign -d "$APP" >/dev/null 2>&1; then
    echo "error: the public app still has a signing identity." >&2
    exit 1
fi
[ -z "$(find "$APP" -name embedded.mobileprovision -o -name _CodeSignature)" ] \
    || { echo "error: signing metadata remains in the public app." >&2; exit 1; }
ditto -c -k --norsrc --noextattr --keepParent "$WORK/Payload" "$OUTPUT"
echo "Created $OUTPUT without provisioning profiles or signatures; re-sign before installing."
