#!/bin/bash
#
# Checks Catalog/catalog.json and signs it with the publisher key (Tools/Catalog/catalog_signing_key,
# never committed). Commit and push both files afterwards; apps pick the catalog up from GitHub.
#
# Apps install a catalog from GitHub only if its catalogVersion is higher than the one they
# have, so raise it whenever the published catalog changes.
#
# Usage: Tools/Catalog/sign-catalog.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CATALOG="$HERE/../../Catalog/catalog.json"
SIGNER="$(mktemp -d)/runfern-sign"

python3 - "$CATALOG" <<'PYTHON'
import json, sys
catalog = json.load(open(sys.argv[1]))
for image in catalog["baseImages"]:
    source = image.get("source")
    if source and (not source["url"].startswith("https://") or len(source["sha256"]) != 64):
        sys.exit(f"error: {image['id']} needs an https URL and a SHA-256 checksum.")
for toolchain in catalog["toolchains"]:
    for package in toolchain["packages"]:
        if not package["url"].startswith("https://") or len(package["sha256"]) != 64:
            sys.exit(f"error: a package of {toolchain['id']} needs an https URL and a SHA-256 checksum.")
print(f"Catalog version {catalog['catalogVersion']}, published {catalog['publishedAt']}")
PYTHON

xcrun swiftc -O "$HERE/sign.swift" -o "$SIGNER"
"$SIGNER" sign "$CATALOG"
