#!/bin/bash
# Attaches the audited native runtime and the pinned license artifacts to a draft app release.
# The App Release workflow verifies exactly these files once the draft is published.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG="${1:?usage: stage-release.sh v<version>}"
cd "$ROOT"

bash Tools/Build/check-version.sh "$TAG"
[ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" = true ] \
    || { echo "error: $TAG must be an existing draft release." >&2; exit 1; }
python3 Tools/Licenses/verify.py --runtime-root . --artifacts build/licenses --release --flavor no-jit

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
COPYFILE_DISABLE=1 tar --no-mac-metadata --uid 0 --gid 0 -czf "$OUT/Runfern-native-runtime.tar.gz" \
    Vendor/QEMU Vendor/JIT Runfern/Resources/Licenses
(cd "$OUT" && shasum -a 256 Runfern-native-runtime.tar.gz > Runfern-native-runtime.tar.gz.sha256)

assets=("$OUT/Runfern-native-runtime.tar.gz" "$OUT/Runfern-native-runtime.tar.gz.sha256")
while IFS= read -r name; do
    assets+=("build/licenses/$name")
done < <(python3 -c 'import json; print("\n".join(json.load(open("Tools/Licenses/release-artifacts.json"))["sha256"]))')
gh release upload "$TAG" "${assets[@]}" --clobber
echo "Staged ${#assets[@]} assets on draft $TAG. Publish it to start the App Release workflow."
