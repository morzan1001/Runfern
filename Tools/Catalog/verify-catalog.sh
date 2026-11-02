#!/bin/bash
#
# Checks the catalog the way apps will load it: its shape (catalog_release.py check: every published
# image and every toolchain package pinned to an HTTPS address and a SHA-256 checksum) and its Ed25519
# signature against the publisher key built into the app (Runfern/Catalog/CatalogStore.swift).
# An app that can't verify the catalog falls back to an empty one, so the "Catalog" workflow runs
# this for every change, and sign-catalog.sh runs it on each new signature.
#
# Verifies with OpenSSL 3 (on a Mac Homebrew's openssl@3), else on a Mac with CryptoKit (sign.swift).
#
# Usage: Tools/Catalog/verify-catalog.sh [<catalog> [<signature>]]
#        defaults: Catalog/catalog.json and the .sig next to the catalog

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CATALOG="${1:-$ROOT/Catalog/catalog.json}"
SIGNATURE="${2:-$CATALOG.sig}"
APP_KEY_SOURCE="$ROOT/Runfern/Catalog/CatalogStore.swift"

fail() { echo "error: $*" >&2; exit 1; }

# OpenSSL 3 or later signs and verifies Ed25519 (-rawin); the Mac's own LibreSSL doesn't.
find_openssl() {
    local candidate
    for candidate in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
        if command -v "$candidate" >/dev/null && "$candidate" version 2>/dev/null | grep -Eq '^OpenSSL ([3-9]|[1-9][0-9])\.'; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

[ -f "$CATALOG" ] || fail "$CATALOG is missing."
[ -f "$SIGNATURE" ] || fail "$SIGNATURE is missing; sign the catalog with Tools/Catalog/sign-catalog.sh."
python3 "$HERE/catalog_release.py" --catalog "$CATALOG" check

APP_KEY="$(sed -n 's/.*publisherKey = "\([^"]*\)".*/\1/p' "$APP_KEY_SOURCE")"
[ -n "$APP_KEY" ] || fail "no publisherKey in $APP_KEY_SOURCE."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Decodes key and signature as the app does (the signature is base64 text; surrounding whitespace
# doesn't count) and writes them for OpenSSL: the key as SubjectPublicKeyInfo (RFC 8410), the
# signature raw.
python3 - "$APP_KEY" "$SIGNATURE" "$WORK" <<'PYTHON'
import base64, binascii, sys
key_text, signature_path, work = sys.argv[1:]

def decode(text, length, what):
    try:
        value = base64.b64decode(text.strip(), validate=True)
    except (binascii.Error, ValueError):
        value = b""
    if len(value) != length:
        sys.exit(f"error: {what} isn't a base64-encoded {length}-byte Ed25519 value.")
    return value

key = decode(key_text, 32, "the app's publisherKey")
signature = decode(open(signature_path, "rb").read().decode("ascii", "replace"), 64, signature_path)
open(f"{work}/public_key.der", "wb").write(bytes.fromhex("302a300506032b6570032100") + key)
open(f"{work}/signature.bin", "wb").write(signature)
PYTHON

MISMATCH="the signature $SIGNATURE doesn't match $CATALOG and the app's publisher key $APP_KEY.
Apps would reject this catalog and fall back to an empty one; sign it with Tools/Catalog/sign-catalog.sh."
if OPENSSL="$(find_openssl)"; then
    "$OPENSSL" pkeyutl -verify -pubin -inkey "$WORK/public_key.der" -keyform DER -rawin \
        -in "$CATALOG" -sigfile "$WORK/signature.bin" >/dev/null || fail "$MISMATCH"
elif [ "$(uname -s)" = Darwin ] && command -v xcrun >/dev/null; then
    xcrun swiftc -O "$HERE/sign.swift" -o "$WORK/runfern-sign"
    "$WORK/runfern-sign" verify "$CATALOG" "$SIGNATURE" "$APP_KEY" >/dev/null || fail "$MISMATCH"
else
    fail "verifying the signature needs OpenSSL 3 (on a Mac: brew install openssl@3, or Xcode)."
fi
echo "The signature matches the app's publisher key."
