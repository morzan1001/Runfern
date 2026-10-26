#!/bin/bash
#
# Builds a minimal QEMU (aarch64-softmmu, threaded TCG interpreter, no JIT) for iOS and the
# iOS simulator as frameworks that Runfern loads at runtime (Plan 4.1, ADR01).
#
# The heavy lifting reuses UTM's proven cross-compilation script; this wrapper only trims it
# to what Runfern needs: no display, audio, USB, SPICE, or GPU stacks.
#
# Usage: build-qemu-ios.sh <path-to-UTM-checkout> [ios-tci|ios_simulator-tci ...]
#
# Output: <UTM>/sysroot-<platform>-arm64/Frameworks/*.framework
#
# Licensing: QEMU is GPLv2. Distributing the app with these frameworks requires providing
# the corresponding source (see Tools/QEMU/README.md).

set -euo pipefail

UTM_DIR="$(cd "${1:?Path to UTM checkout required}" && pwd)"
shift
PLATFORMS=("${@:-ios_simulator-tci ios-tci}")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRIMMED="$UTM_DIR/scripts/build_runfern_qemu.sh"

python3 "$SCRIPT_DIR/trim_build_script.py" "$UTM_DIR/scripts/build_dependencies.sh" "$TRIMMED"
chmod +x "$TRIMMED"

export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/gettext/bin:$PATH"

cd "$UTM_DIR"
for platform in ${PLATFORMS[@]}; do
    echo "=== Building QEMU for $platform ==="
    "$TRIMMED" -p "$platform" -a arm64
done
echo "=== QEMU build finished ==="
