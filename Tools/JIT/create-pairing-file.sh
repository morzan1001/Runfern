#!/bin/bash
#
# Creates the Remote Pairing file (RPPairing) that Runfern's built-in JIT needs, on a computer.
# Runfern on iPadOS 27 can also create it by itself (Settings > Performance > Create on This
# iPad...); this script is the way for a computer the iPad already trusts.
#
#   Tools/JIT/create-pairing-file.sh [--udid <UDID>] [--output <file>]
#   Tools/JIT/create-pairing-file.sh --wifi [--output <file>]
#
# Over USB (default), the iPad pairs with a new host identity over remotepairingdeviced's lockdown
# channel. USB lockdown already trusts this computer, so no Trust prompt should appear. The script
# then checks the file against the iPad (pair-verify), the way StikJIT will use it.
#
# With --wifi, this computer advertises itself as a pairable host on the local network. On the
# iPad, open Settings > Privacy & Security > Developer Mode > Pair with <name>, and type the code
# this script shows. No cable is needed, but both must be on the same Wi-Fi network.
#
# The file holds public_key, private_key, identifier, and alt_irk: exactly what StikJIT reads
# (idevice's RpPairingFile). It is a secret: whoever has it can use the iPad's developer services.
# Send it to the iPad (AirDrop, or Finder's Files tab), import it in Runfern (Settings >
# Performance > Import Pairing File...), then delete every copy. It stops working when the iPad's
# passcode is changed or removed; run this script again then. Every run adds another trusted host
# on the iPad, which you can remove under Settings > Privacy & Security > Developer Mode.
#
# Needs: macOS (iPad trusted in Finder once) or Linux (usbmuxd running); for the one-time build of
# idevice's tools (10 minutes or more): Rust 1.88 or newer (https://rustup.rs), a C toolchain and
# cmake (Xcode Command Line Tools and `brew install cmake`; on Linux build-essential, cmake,
# pkg-config), and access to github.com and crates.io.
# Windows: use idevice_pair 1.1.0 ("Pair over Wi-Fi", or "Remote pairing" over USB) or iloader
# 2.4.1 (Manage Pairing File > Export) instead.

set -euo pipefail

# idevice logs the parsed pairing file, private key included, at debug level.
export RUST_LOG=error

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
IDEVICE_VERSION="0.1.68"
IDEVICE_REV="d32c8189c51c2789496b0768039419c3705498c3"  # tag v0.1.68 (MIT)
TOOLS="$REPO/Vendor/JIT/host/idevice-tools-$IDEVICE_VERSION"
BIN="$TOOLS/bin/idevice-tools"
LIST="$TOOLS/bin/idevice_id"
PAIR_HOST="$TOOLS/bin/pair_host"

fail () { echo "error: $1" >&2; exit 1; }
usage () { echo "usage: $0 [--udid <UDID>] [--output <file>] | --wifi [--output <file>]" >&2; exit 64; }

UDID=""
OUTPUT=""
WIFI=0
while [ $# -gt 0 ]; do
    case "$1" in
        --udid) [ $# -ge 2 ] || usage; UDID="$2"; shift 2 ;;
        --output) [ $# -ge 2 ] || usage; OUTPUT="$2"; shift 2 ;;
        --wifi) WIFI=1; shift ;;
        *) usage ;;
    esac
done
[ "$WIFI" = 0 ] || [ -z "$UDID" ] || usage

if [ -z "$OUTPUT" ]; then
    if [ -d "$HOME/Desktop" ]; then OUTPUT="$HOME/Desktop/pairingFile.plist"; else OUTPUT="$HOME/pairingFile.plist"; fi
fi
[ -e "$OUTPUT" ] && fail "$OUTPUT already exists; move it away or pass --output."
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd -P)/$(basename "$OUTPUT")"
case "$OUTPUT" in
    "$(cd "$REPO" && pwd -P)"/*) fail "do not write the pairing file into the repository; pass --output outside $REPO." ;;
esac

# 1. idevice's tools, built once from a pinned commit.
if [ ! -x "$BIN" ] || [ ! -x "$LIST" ] || [ ! -x "$PAIR_HOST" ]; then
    command -v cargo >/dev/null 2>&1 || fail "Rust is missing; install it from https://rustup.rs"
    rust_minor="$(rustc --version | awk '{split($2, v, "."); print (v[1] > 1) ? 999 : v[2]}')"
    [ "$rust_minor" -ge 88 ] || fail "Rust 1.88 or newer is needed; run: rustup update stable"
    command -v cmake >/dev/null 2>&1 || fail "cmake is missing (macOS: brew install cmake; Linux: your package manager)."
    if [ "$(uname)" = Darwin ]; then
        xcode-select -p >/dev/null 2>&1 || fail "the Xcode Command Line Tools are missing; run: xcode-select --install"
    fi
    echo "=== Building idevice's tools $IDEVICE_VERSION (once; 10 minutes or more) ==="
    cargo install --locked --root "$TOOLS" \
        --git https://github.com/jkcoxson/idevice --rev "$IDEVICE_REV" \
        idevice-tools --bin idevice-tools --bin idevice_id --bin pair_host
fi

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
label="runfern-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"

finish () {
    mv "$work/pairingFile.plist" "$OUTPUT"
    chmod 600 "$OUTPUT"
    echo "Pairing file: $OUTPUT"
    cat <<EOF
Next: send it to the iPad (AirDrop, or Finder's Files tab), open Runfern > Settings > Performance >
Import Pairing File..., pick it, then delete every copy of it. It stops working when the iPad's
passcode is changed or removed; create a new one then.
EOF
}

# 2a. Over Wi-Fi: the iPad starts the pairing (iPadOS 27 and later).
if [ "$WIFI" = 1 ]; then
    echo "=== Waiting for the iPad (5 minutes at most) ==="
    echo "On the iPad: Settings > Privacy & Security > Developer Mode > Pair with $label,"
    echo "then type the code shown below. Keep both on the same Wi-Fi network."
    "$PAIR_HOST" --name "$label" --out "$work/pairingFile.plist" &
    pair_pid=$!
    ( sleep 300; kill "$pair_pid" 2>/dev/null ) &
    watchdog=$!
    status=0
    wait "$pair_pid" || status=$?
    kill "$watchdog" 2>/dev/null || true
    [ "$status" = 0 ] && [ -s "$work/pairingFile.plist" ] || fail "pairing did not complete (see above)."
    finish
    exit 0
fi

# 2b. Over USB: exactly one iPad, trusted by this computer.
if [ -z "$UDID" ]; then
    devices="$("$LIST" 2>/dev/null)" || fail "usbmuxd is not reachable (Linux: start the usbmuxd service)."
    udids="$(printf '%s\n' "$devices" | awk '
        /connection_type:/ { usb = ($0 ~ /connection_type: Usb/) }
        usb && /udid:/ { gsub(/[",]/, "", $2); print $2 }' | sort -u)"
    count="$(printf '%s\n' "$udids" | grep -c . || true)"
    [ "$count" -ge 1 ] || fail "no iPad connected over USB."
    [ "$count" -eq 1 ] || fail "several devices are connected; pass --udid with one of: $(echo $udids)"
    UDID="$udids"
fi

product_version () {
    "$BIN" --udid "$UDID" lockdown get ProductVersion 2>/dev/null | tail -n 1 | tr -d '"' || true
}
version="$(product_version)"
case "$version" in
    [0-9]*) ;;
    *)
        if [ "$(uname)" = Darwin ]; then
            fail "the iPad does not trust this computer yet: unlock it, select it in Finder and tap Trust."
        fi
        echo "The iPad does not trust this computer yet. Unlock it, then tap Trust and enter its passcode."
        # Prints the new lockdown record, which is a secret too.
        "$BIN" --udid "$UDID" pair "$UDID" >/dev/null || fail "pairing with usbmuxd failed."
        version="$(product_version)"
        ;;
esac
case "$version" in
    [0-9]*) ;;
    *) fail "the iPad does not trust this computer (no answer from lockdown); unlock it and try again." ;;
esac
major="${version%%.*}"
[ "$major" -ge 27 ] || fail "this iPad runs iPadOS $version; Runfern needs iPadOS 27 or later."

developer_mode="$("$BIN" --udid "$UDID" amfi status 2>/dev/null | tail -n 1)" || developer_mode=""
case "$developer_mode" in
    *true*) ;;
    *) echo "warning: Developer Mode looks off; JIT needs it (Settings > Privacy & Security > Developer Mode)." >&2 ;;
esac

# 3. Pair over USB under a new host name, so earlier pairings stay untouched.
echo "=== Pairing with $UDID (iPadOS $version) as $label ==="
"$BIN" --udid "$UDID" remotepairing_lockdown pair "$label" "$work/pairingFile.plist" >/dev/null
# The tool reports a failed pairing on stderr but still exits 0, so check for the file.
[ -s "$work/pairingFile.plist" ] || fail "pairing failed (see above); keep the iPad unlocked and try again."

# 4. Check the file the way StikJIT will use it.
verdict="$("$BIN" --udid "$UDID" remotepairing_lockdown verify "$work/pairingFile.plist" "$label" 2>&1)" || true
case "$verdict" in
    *"the device recognizes this pairing record"*) ;;
    *) fail "the iPad does not accept the new pairing file: $verdict" ;;
esac

finish
