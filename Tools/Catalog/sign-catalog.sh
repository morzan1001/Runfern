#!/bin/bash
#
# Checks Catalog/catalog.json and signs it with the publisher key. Commit and push both files
# afterwards; apps pick the catalog up from GitHub.
#
# The key is the base64-encoded 32-byte Ed25519 private key that sign.swift keygen creates, taken
# from the environment variable CATALOG_SIGNING_KEY (in GitHub Actions the secret of the
# environment "catalog") or else from Tools/Catalog/catalog_signing_key (never committed).
# Before signing, the script checks that the key belongs to the publisher key built into the app
# (Runfern/Catalog/CatalogStore.swift), and it replaces Catalog/catalog.json.sig only once
# verify-catalog.sh accepts the new signature.
# Signs with sign.swift (CryptoKit) on a Mac with Xcode, else with OpenSSL 3.
#
# Apps install a catalog from GitHub only if its catalogVersion is higher than the one they
# have, so raise it whenever the published catalog changes (catalog_release.py finish).
#
# Usage: Tools/Catalog/sign-catalog.sh               checks and signs the catalog
#        Tools/Catalog/sign-catalog.sh --check-key   only checks the key

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CATALOG="$ROOT/Catalog/catalog.json"
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

case "${1:-}" in
    "") CHECK_KEY_ONLY=false ;;
    --check-key) CHECK_KEY_ONLY=true ;;
    *) fail "usage: $0 [--check-key]" ;;
esac

[ "$CHECK_KEY_ONLY" = true ] || python3 "$HERE/catalog_release.py" check

# The private key exists only in the given file or in this private directory, removed on exit,
# and is never printed.
umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "${CATALOG_SIGNING_KEY:-}" ]; then
    KEY_FILE="$WORK/signing_key"
    printf '%s' "$CATALOG_SIGNING_KEY" > "$KEY_FILE"
elif [ -f "$HERE/catalog_signing_key" ]; then
    KEY_FILE="$HERE/catalog_signing_key"
else
    fail "no signing key: set CATALOG_SIGNING_KEY or create Tools/Catalog/catalog_signing_key (README.md, Catalog)."
fi

# Checks the key's form and writes it as PKCS#8 (RFC 8410) for OpenSSL.
python3 - "$KEY_FILE" "$WORK/signing_key.der" <<'PYTHON'
import base64, binascii, sys
try:
    seed = base64.b64decode(open(sys.argv[1], "rb").read().strip(), validate=True)
except (binascii.Error, ValueError):
    seed = b""
if len(seed) != 32:
    sys.exit("error: the signing key isn't a base64-encoded 32-byte Ed25519 key (the content of catalog_signing_key).")
open(sys.argv[2], "wb").write(bytes.fromhex("302e020100300506032b657004220420") + seed)
PYTHON

if [ "$(uname -s)" = Darwin ] && command -v xcrun >/dev/null; then
    SIGNER="$WORK/runfern-sign"
    xcrun swiftc -O "$HERE/sign.swift" -o "$SIGNER"
    SIGNING_KEY_PUBLIC="$("$SIGNER" pubkey "$KEY_FILE")"
else
    SIGNER=""
    OPENSSL="$(find_openssl)" || fail "signing needs OpenSSL 3 (on a Mac: Xcode, or brew install openssl@3)."
    "$OPENSSL" pkey -inform DER -in "$WORK/signing_key.der" -pubout -outform DER -out "$WORK/public_key.der"
    SIGNING_KEY_PUBLIC="$(python3 -c 'import base64, sys; print(base64.b64encode(open(sys.argv[1], "rb").read()[-32:]).decode())' "$WORK/public_key.der")"
fi

APP_KEY="$(sed -n 's/.*publisherKey = "\([^"]*\)".*/\1/p' "$APP_KEY_SOURCE")"
[ -n "$APP_KEY" ] || fail "no publisherKey in $APP_KEY_SOURCE."
if [ "$SIGNING_KEY_PUBLIC" != "$APP_KEY" ]; then
    fail "the signing key belongs to the public key $SIGNING_KEY_PUBLIC, but the app verifies catalogs
with $APP_KEY (publisherKey in Runfern/Catalog/CatalogStore.swift). Apps would reject the catalog:
check the CATALOG_SIGNING_KEY secret or Tools/Catalog/catalog_signing_key."
fi
echo "The signing key belongs to the app's publisher key."
[ "$CHECK_KEY_ONLY" = false ] || exit 0

# Signs a copy, so the published signature is replaced only by one that verifies.
cp "$CATALOG" "$WORK/catalog.json"
if [ -n "$SIGNER" ]; then
    "$SIGNER" sign "$WORK/catalog.json" "$KEY_FILE" >/dev/null
else
    "$OPENSSL" pkeyutl -sign -inkey "$WORK/signing_key.der" -keyform DER -rawin \
        -in "$WORK/catalog.json" -out "$WORK/signature.bin"
    python3 -c 'import base64, sys; open(sys.argv[2], "w").write(base64.b64encode(open(sys.argv[1], "rb").read()).decode())' \
        "$WORK/signature.bin" "$WORK/catalog.json.sig"
fi
"$HERE/verify-catalog.sh" "$CATALOG" "$WORK/catalog.json.sig"
install -m 0644 "$WORK/catalog.json.sig" "$CATALOG.sig"
echo "Signed Catalog/catalog.json; commit and push it with Catalog/catalog.json.sig."
