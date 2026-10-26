#!/bin/bash
#
# Copies QEMU and exactly the frameworks it links against from a finished build into
# Vendor/QEMU/<sdk>/, where the "Embed QEMU" build phase picks them up.
#
# Usage: install-vendor.sh <path-to-UTM-checkout>

set -euo pipefail

UTM_DIR="$(cd "${1:?Path to UTM checkout required}" && pwd)"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT_FRAMEWORK="qemu-aarch64-softmmu"

install_platform () {
    local sysroot="$UTM_DIR/$1/Frameworks"
    local target="$REPO/Vendor/QEMU/$2"
    if [ ! -d "$sysroot/$ROOT_FRAMEWORK.framework" ]; then
        echo "Skipping $2: no build in $sysroot"
        return
    fi
    rm -rf "$target"
    mkdir -p "$target"

    # Breadth-first walk over @rpath framework dependencies.
    local queue=("$ROOT_FRAMEWORK") seen=" "
    while [ ${#queue[@]} -gt 0 ]; do
        local name="${queue[0]}"
        queue=("${queue[@]:1}")
        case "$seen" in *" $name "*) continue ;; esac
        seen="$seen$name "
        cp -R "$sysroot/$name.framework" "$target/"
        for dependency in $(otool -L "$sysroot/$name.framework/$name" | awk '/@rpath\/.*\.framework/ { print $1 }'); do
            queue+=("$(basename "$dependency")")
        done
    done
    # Debug symbols are not needed at runtime and make up much of the size.
    for framework in "$target"/*.framework; do
        strip -x "$framework/$(basename "$framework" .framework)" 2>/dev/null || true
    done
    echo "Installed into $target:"
    du -sh "$target"/*.framework
}

# Adds QEMU with the JIT backend next to the interpreter build, renamed so both can be embedded.
# It links against the same libraries, which the interpreter build already installed.
install_jit () {
    local source="$UTM_DIR/$1/Frameworks/$ROOT_FRAMEWORK.framework"
    local target="$REPO/Vendor/QEMU/$2"
    local name="$ROOT_FRAMEWORK-jit"
    if [ ! -d "$source" ] || [ ! -d "$target" ]; then
        echo "Skipping JIT for $2: no build in $source or no interpreter build installed"
        return
    fi
    rm -rf "$target/$name.framework"
    cp -R "$source" "$target/$name.framework"
    mv "$target/$name.framework/$ROOT_FRAMEWORK" "$target/$name.framework/$name"
    install_name_tool -id "@rpath/$name.framework/$name" "$target/$name.framework/$name"
    plutil -replace CFBundleExecutable -string "$name" "$target/$name.framework/Info.plist"
    plutil -replace CFBundleName -string "$name" "$target/$name.framework/Info.plist"
    plutil -replace CFBundleIdentifier -string "org.qemu.$name" "$target/$name.framework/Info.plist"
    for dependency in $(otool -L "$target/$name.framework/$name" | awk '/@rpath\/.*\.framework/ { print $1 }'); do
        local dependencyName="$(basename "$dependency")"
        [ "$dependencyName" = "$name" ] && continue
        [ -d "$target/$dependencyName.framework" ] || { echo "Missing dependency $dependencyName for $name"; exit 1; }
    done
    strip -x "$target/$name.framework/$name" 2>/dev/null || true
    echo "Installed $name into $target"
}

install_platform "sysroot-iOS_Simulator-TCI-arm64" "iphonesimulator"
install_platform "sysroot-iOS-TCI-arm64" "iphoneos"
install_jit "sysroot-iOS-arm64" "iphoneos"
