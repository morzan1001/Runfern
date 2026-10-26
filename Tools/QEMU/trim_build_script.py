#!/usr/bin/env python3
"""Derives Runfern's minimal QEMU build script from UTM's build_dependencies.sh.

Replaces whole shell functions and the final build sequence so that only QEMU and the
libraries it strictly needs are downloaded and built. Fails loudly if UTM's script
changes shape, instead of silently building the wrong thing.
"""
import re
import sys

source_path, target_path = sys.argv[1], sys.argv[2]
script = open(source_path).read()


def replace_function(name: str, body: str) -> None:
    global script
    pattern = re.compile(rf"^{name} \(\) \{{\n.*?^\}}\n", re.S | re.M)
    script, count = pattern.subn(f"{name} () {{\n{body}\n}}\n", script)
    if count != 1:
        sys.exit(f"Function {name} not found exactly once")


def replace_text(old: str, new: str) -> None:
    global script
    if old not in script:
        sys.exit(f"Text not found: {old[:60]}")
    script = script.replace(old, new)


# Only the tools needed for this reduced build.
replace_function("check_env", """\
    command -v meson >/dev/null 2>&1 || { echo >&2 "meson is required"; exit 1; }
    command -v ninja >/dev/null 2>&1 || { echo >&2 "ninja is required"; exit 1; }
    command -v msgfmt >/dev/null 2>&1 || { echo >&2 "gettext (msgfmt) is required"; exit 1; }
    command -v glib-mkenums >/dev/null 2>&1 || { echo >&2 "glib-utils are required"; exit 1; }
    command -v xcrun >/dev/null 2>&1 || { echo >&2 "xcrun is required"; exit 1; }""")

replace_function("download_all", """\
    [ -d "$BUILD_DIR" ] || mkdir -p "$BUILD_DIR"
    download $PKG_CONFIG_SRC
    download $FFI_SRC
    download $ICONV_SRC
    download $GETTEXT_SRC
    download $GLIB_SRC
    download $PIXMAN_SRC
    download $ZSTD_SRC
    download $SLIRP_SRC
    download $QEMU_SRC
    clone $LIBUCONTEXT_REPO $LIBUCONTEXT_COMMIT""")

replace_function("build_qemu_dependencies", """\
    build $FFI_SRC
    build $ICONV_SRC
    gl_cv_onwards_func_strchrnul=future build $GETTEXT_SRC --disable-java
    meson_build $GLIB_SRC -Dtests=false -Ddtrace=disabled
    build $PIXMAN_SRC
    ZSTD_BASENAME="$(basename $ZSTD_SRC)"
    meson_build "$BUILD_DIR/${ZSTD_BASENAME%.tar.*}/build/meson"
    meson_darwin_build $SLIRP_SRC
    meson_build $LIBUCONTEXT_REPO -Ddefault_library=static -Dfreestanding=true""")

# Runfern runs exactly one guest architecture and needs no device emulation beyond virtio.
replace_text(
    "--target-list=aarch64-softmmu,i386-softmmu,ppc-softmmu,ppc64-softmmu,riscv64-softmmu,x86_64-softmmu,m68k-softmmu",
    "--target-list=aarch64-softmmu --disable-spice --disable-opengl --disable-png --disable-vnc "
    "--disable-usb-redir --disable-libusb --disable-gnutls --disable-gcrypt --disable-tpm",
)

# App Store apps cannot use the private hypervisor; Runfern relies on the interpreter only.
replace_text('HVF_FLAGS="--enable-hvf-private"', 'HVF_FLAGS="--disable-hvf"')

replace_text(
    "build_spice_client\nbuild_vulkan_drivers\nbuild_d3d_drivers\nfixup_all\nremove_shared_gst_plugins # another hack...\n",
    "fixup_all\n",
)

open(target_path, "w").write(script)
print(f"Wrote {target_path}")
