#!/bin/bash
#
# Xcode build phase "Embed Catalog": copies the published catalog (Catalog/catalog.json and its
# signature) into the app as the bundled baseline, so the app and the catalog on GitHub always
# come from the same file. The app verifies the signature again when it loads the catalog.

set -euo pipefail

SOURCE="$SRCROOT/Catalog"
TARGET="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"

for file in catalog.json catalog.json.sig; do
    [ -f "$SOURCE/$file" ] || { echo "error: $SOURCE/$file is missing." >&2; exit 1; }
    install -m 0644 "$SOURCE/$file" "$TARGET/$file"
done
