#!/usr/bin/env python3
"""Builds a Runfern Linux base image bundle (see ImageBundle.swift) on a Mac or on Linux.

The official cloud image of the distribution is customized once in a QEMU VM via cloud-init:
GuestAgent, openvscode-server, the Runfern extension, a kernel with 9p support, the libraries
the catalog's toolchains need, and the /workspace mount. Distributions differ only in their
package manager (FLAVORS). The VM writes kernel, initrd, and kernel command line to an extra raw
disk as a tar stream, then powers off.

The VM runs hardware-accelerated where the host can run the arm64 guest natively (HVF on Apple
silicon, KVM on arm64 Linux with access to /dev/kvm), and emulated with TCG everywhere else, for
example on GitHub's runners without /dev/kvm. The image is the same; TCG just takes hours instead
of minutes.

Usage: build_image.py <id>        ids: see BASES (debian-12-arm64, fedora-44-arm64, ...)

Requirements:
    macOS           brew install qemu
    Debian/Ubuntu   apt-get install qemu-system-arm qemu-efi-aarch64 qemu-utils xorriso zstd

Optional environment:
    RUNFERN_ACCEL                       hvf, kvm, or tcg instead of the automatic choice
    RUNFERN_BUILD_TIMEOUT               seconds the VM may take (default 3600; 19800 with tcg)
    RUNFERN_EFI_CODE, RUNFERN_EFI_VARS  UEFI firmware and variable store template for the VM
    GITHUB_TOKEN or GH_TOKEN            for GitHub's API, whose anonymous limit CI runners share

Output in Tools/GuestImage/build/<id>/:
    <id>.runfernimage   ustar bundle to publish
    <id>.sha256         checksum for the catalog's ImageSource
    <id>.json           id, size, and checksum (also printed), for CI
"""
import base64
import gzip
import hashlib
import io
import json
import os
import pathlib
import platform
import re
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
import uuid
import zipfile
import image_evidence

HERE = pathlib.Path(__file__).resolve().parent
FILES = HERE / "files"

# Immutable official builds; checksums are from their publishers' checksum files.
BASES = {
    "debian-12-arm64": {"flavor": "apt", "kernel": "linux-image-arm64",
                        "url": "https://cloud.debian.org/images/cloud/bookworm/20261026-2643/debian-12-genericcloud-arm64-20261026-2643.qcow2",
                        "sha512": "f42866fe22b4baf9f0ed4f81d620064f2a4b86b18b92bfe3aaaa40babf6819d39cbf0caaaad13f4ae3e7c9f82cbd78b0c8cabadd8bc737ce13578e61fa86970c"},
    "debian-13-arm64": {"flavor": "apt", "kernel": "linux-image-arm64",
                        "url": "https://cloud.debian.org/images/cloud/trixie/20261026-2643/debian-13-genericcloud-arm64-20261026-2643.qcow2",
                        "sha512": "71aa5d5dbcb3d9ecfe96bc3f6dd41b6805a0a41c852204a32747d230b64b95912297fb453b11a6031fd54d84a0a0a430e137d07e6986dc9ebc9d41483be003c4"},
    "ubuntu-24.04-arm64": {"flavor": "apt", "kernel": "linux-image-generic",
                           "url": "https://cloud-images.ubuntu.com/noble/20261017/noble-server-cloudimg-arm64.img",
                           "sha256": "50e24e1fb79e89116e939d90aa7738f7af48c442fa1bc2510131e0b39c50348e"},
    "ubuntu-26.04-arm64": {"flavor": "apt", "kernel": "linux-image-generic",
                           "url": "https://cloud-images.ubuntu.com/resolute/20261016/resolute-server-cloudimg-arm64.img",
                           "sha256": "8eb876c2ccc4b6ff89e4a65d511815923b285e04503ba465809bf587f763da24"},
    "fedora-44-arm64": {"flavor": "dnf", "kernel": "kernel-core kernel-modules",
                        "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2",
                        "sha256": "55c60a3b80d3616a08705afd0459e75fe9f03c54aba7a46e4002a41a72fa0d5b"},
}
EDITOR = {
    "version": "openvscode-server-v1.109.5",
    "url": "https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v1.109.5/openvscode-server-v1.109.5-linux-arm64.tar.gz",
    "sha256": "36d9c14036489b63de84ebace837fcacf7e60e669a0dc715802c5443684ea4dc",
    "sourceURL": "https://codeload.github.com/gitpod-io/openvscode-server/tar.gz/4ffe2270acdf711bbefecc3e8c79f4b3631640e5",
    "sourceSHA256": "8e8969232ca7904f1f48682c621d91cb5217779744693e4e4021b6ed1bd0a8de",
}

# What differs between package managers: packages (tools, and the libraries Swift, .NET, Flutter,
# and native modules link against), installing the kernel, and building the initramfs.
COMMON_TOOLS = ["python3", "git", "curl", "ca-certificates", "unzip", "zip", "less", "nano", "tar"]
FLAVORS = {
    "apt": {
        "packages": COMMON_TOOLS + ["build-essential", "openssh-client", "xz-utils", "procps", "pkg-config", "tzdata",
                                    "libicu-dev", "libcurl4-openssl-dev", "libxml2-dev", "libncurses-dev",
                                    "libsqlite3-dev", "zlib1g-dev", "libpython3-dev", "libedit2"],
        "install_packages": "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {packages}",
        "install_kernel": "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {kernel}",
        "quiet": "systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer || true",
        "clean": "apt-get clean; rm -rf /var/lib/apt/lists/*",
    },
    "dnf": {
        "packages": COMMON_TOOLS + ["gcc", "gcc-c++", "make", "openssh-clients", "xz", "procps-ng", "pkgconf", "tzdata",
                                    "libicu", "libcurl-devel", "libxml2-devel", "ncurses-devel", "sqlite-devel",
                                    "zlib-devel", "python3-devel", "libedit", "dracut", "dnf5-plugins"],
        "install_packages": "dnf -y install --setopt=install_weak_deps=False {packages}",
        "install_kernel": "dnf -y install --setopt=install_weak_deps=False {kernel}",
        "quiet": "systemctl disable --now dnf-makecache.timer || true",
        "clean": "dnf clean all",
    },
}
DISK_SIZE = "16G"
# Drivers the initramfs needs to find the disk and the shares before the root file system is up.
BOOT_MODULES = ["virtio_pci", "virtio_blk", "virtio_net", "virtio_console", "9p", "9pnet_virtio"]
AGENT_PROTOCOL_VERSION = 1

# The customization VM. Emulated (tcg) it needs hours, so it gets most of a 6 hour CI job.
ACCELERATORS = ("hvf", "kvm", "tcg")
KVM_DEVICE = "/dev/kvm"
ACCELERATED_TIMEOUT = 3600
EMULATED_TIMEOUT = 19800
MAX_VCPUS = 4
# QEMU's virt machine has two 64 MiB flash devices and accepts only images of exactly that size.
VIRT_FLASH_SIZE = 64 << 20
# UEFI firmware and variable store template from distribution packages, after Homebrew's.
SYSTEM_FIRMWARE = [("/usr/share/qemu/edk2-aarch64-code.fd", "/usr/share/qemu/edk2-arm-vars.fd"),
                   ("/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/AAVMF/AAVMF_VARS.fd")]  # qemu-efi-aarch64
# Programs that write the cloud-init seed ISO on Linux, preferred first.
ISO_TOOLS = ("xorriso", "genisoimage", "mkisofs", "cloud-localds")
# The bundle's files in archive order (see ImageBundle.swift).
BUNDLE_FILES = ["image.json", "disk.qcow2", "vmlinuz", "initrd.img"]
# GitHub refuses release assets of 2 GiB or more.
RELEASE_ASSET_LIMIT = 2 << 30


def run(*command, **options):
    print("+", " ".join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **options)


def is_macos():
    return platform.system() == "Darwin"


def sysctl(name):
    """A macOS kernel setting, or "" if the host doesn't have it."""
    try:
        result = subprocess.run(["/usr/sbin/sysctl", "-n", name], capture_output=True, text=True)
    except OSError:
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def accelerator():
    """hvf or kvm where the host runs the arm64 guest natively, tcg (emulation) otherwise."""
    override = os.environ.get("RUNFERN_ACCEL", "").strip()
    if override:
        if override not in ACCELERATORS:
            sys.exit(f"RUNFERN_ACCEL must be one of {', '.join(ACCELERATORS)}, not {override!r}")
        return override
    if is_macos():
        # Intel Macs support Hypervisor.framework too, but only for guests of their own architecture.
        return "hvf" if sysctl("kern.hv_support") == "1" and sysctl("hw.optional.arm64") == "1" else "tcg"
    if platform.system() == "Linux" and platform.machine() in ("aarch64", "arm64"):
        if os.access(KVM_DEVICE, os.R_OK | os.W_OK):
            return "kvm"
        if os.path.exists(KVM_DEVICE):
            print(f"{KVM_DEVICE} exists but this user can't read and write it, so the VM is emulated")
    return "tcg"


def host_cpus():
    try:
        return len(os.sched_getaffinity(0))  # what a container or CI runner actually grants
    except AttributeError:  # macOS
        return os.cpu_count() or 1


def vm_cpu_arguments(accel):
    """QEMU's -accel, -cpu, and -smp. Emulated, every vCPU gets its own host thread, and the
    implementation-defined pointer authentication is much cheaper to emulate than QARMA."""
    cpus = min(host_cpus(), MAX_VCPUS)
    if accel == "tcg":
        return ["-accel", "tcg,thread=multi", "-cpu", "max,pauth-impdef=on", "-smp", cpus]
    return ["-accel", accel, "-cpu", "host", "-smp", cpus]


def build_timeout(accel):
    """Seconds the customization VM may run before the build fails."""
    value = os.environ.get("RUNFERN_BUILD_TIMEOUT", "").strip()
    if value:
        if not value.isdigit() or int(value) == 0:
            sys.exit(f"RUNFERN_BUILD_TIMEOUT must be a positive number of seconds, not {value!r}")
        return int(value)
    return EMULATED_TIMEOUT if accel == "tcg" else ACCELERATED_TIMEOUT


def efi_firmware():
    """UEFI firmware and variable store template for the VM's two flash devices:
    RUNFERN_EFI_CODE and RUNFERN_EFI_VARS if set, else Homebrew's QEMU, else SYSTEM_FIRMWARE."""
    code, variables = os.environ.get("RUNFERN_EFI_CODE"), os.environ.get("RUNFERN_EFI_VARS")
    if code or variables:
        if not (code and variables):
            sys.exit("Set both RUNFERN_EFI_CODE and RUNFERN_EFI_VARS, or neither")
        candidates = [(code, variables)]
    else:
        candidates = []
        if shutil.which("brew"):
            prefix = subprocess.run(["brew", "--prefix", "qemu"], capture_output=True, text=True).stdout.strip()
            if prefix:
                share = pathlib.Path(prefix) / "share/qemu"
                candidates.append((share / "edk2-aarch64-code.fd", share / "edk2-arm-vars.fd"))
        candidates += SYSTEM_FIRMWARE
    for code, variables in candidates:
        code, variables = pathlib.Path(code), pathlib.Path(variables)
        if code.is_file() and variables.is_file():
            # Images for -bios (QEMU_EFI.fd, 2 MiB) don't fit the flash devices.
            if code.stat().st_size == variables.stat().st_size == VIRT_FLASH_SIZE:
                return code, variables
            print(f"Skipping {code} and {variables}: the VM's flash devices need images of exactly "
                  f"{VIRT_FLASH_SIZE} bytes (64 MiB), these have {code.stat().st_size} and {variables.stat().st_size}")
    sys.exit("No UEFI firmware for the VM found. Looked for:\n"
             + "".join(f"    {code} and {variables}\n" for code, variables in candidates)
             + "Install it (macOS: brew install qemu; Debian/Ubuntu: apt-get install qemu-efi-aarch64) "
               "or set RUNFERN_EFI_CODE and RUNFERN_EFI_VARS.")


def seed_iso_tool():
    """The program that writes the cloud-init seed ISO."""
    if is_macos():
        return "hdiutil"
    for tool in ISO_TOOLS:
        if shutil.which(tool):
            return tool
    sys.exit(f"None of {', '.join(ISO_TOOLS)} is installed to create the cloud-init seed ISO. "
             "Install xorriso (apt-get install xorriso, dnf install xorriso), genisoimage, or cloud-image-utils.")


def seed_iso_command(tool, seed, iso):
    """Writes user-data and meta-data from `seed` to an ISO labelled cidata, where cloud-init's
    NoCloud source looks for them. Joliet and Rock Ridge keep the file names intact."""
    files = [seed / "user-data", seed / "meta-data"]
    if tool == "hdiutil":
        return ["hdiutil", "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata",
                "-o", iso, seed]
    if tool == "cloud-localds":
        return ["cloud-localds", iso, *files]
    mkisofs = ["xorriso", "-as", "mkisofs"] if tool == "xorriso" else [tool]
    return mkisofs + ["-quiet", "-output", iso, "-volid", "cidata", "-joliet", "-rock", *files]


def require_programs():
    """Fails before the long VM run rather than after it."""
    needed = ["qemu-img", "qemu-system-aarch64", "zstd"] + ([] if is_macos() else ["tar"])
    missing = [name for name in needed if not shutil.which(name)]
    if missing:
        sys.exit(f"Missing {', '.join(missing)}. Install: brew install qemu (macOS), or apt-get install "
                 "qemu-system-arm qemu-efi-aarch64 qemu-utils xorriso zstd (Debian/Ubuntu)")
    if not is_macos():
        version = subprocess.run(["tar", "--version"], capture_output=True, text=True).stdout
        if "GNU tar" not in version:
            sys.exit("On Linux the bundle is written with GNU tar, but `tar` is another implementation")


def archive_command(archive, bundle, mtime):
    """The tar invocation and environment for the bundle: plain ustar (all TarExtractor.swift reads),
    files in BUNDLE_FILES order. On macOS the system's bsdtar rather than a GNU tar from Homebrew,
    without AppleDouble files. Elsewhere GNU tar with fixed owner, mode, and time, so the archive's
    metadata doesn't depend on the build machine."""
    if is_macos():
        return (["tar", "--format", "ustar", "-cf", archive, "-C", bundle, *BUNDLE_FILES],
                {"COPYFILE_DISABLE": "1", "PATH": "/usr/bin:/bin"})
    return (["tar", "--format=ustar", "--owner=0", "--group=0", "--numeric-owner", "--mode=0644",
             f"--mtime=@{mtime}", "-cf", archive, "-C", bundle, *BUNDLE_FILES], None)


def release_size(archive):
    """The archive's size if GitHub accepts it as a release asset. A larger archive is removed, so
    publish-image.sh can't create a release whose upload then fails; bundle/ keeps its parts."""
    size = archive.stat().st_size
    if size >= RELEASE_ASSET_LIMIT:
        archive.unlink()
        sys.exit(f"{archive} would have {size} bytes, but GitHub release assets must be smaller than 2 GiB "
                 f"({RELEASE_ASSET_LIMIT} bytes). Make the image smaller.")
    return size


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(4 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def console_tail(log, lines=60):
    """The end of the VM's serial console, for build logs where console.log itself isn't at hand."""
    try:
        return "\n".join(log.read_text(errors="replace").splitlines()[-lines:])
    except OSError:
        return "(no console output)"


def runfern_extension_vsix():
    """Packages Tools/GuestImage/extension as a VSIX that openvscode-server can install offline."""
    package = json.loads((HERE / "extension" / "package.json").read_text())
    identity = f"{package['publisher']}.{package['name']}"
    manifest = f"""<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="{package['name']}" Version="{package['version']}" Publisher="{package['publisher']}"/>
    <DisplayName>{package['displayName']}</DisplayName>
    <Description xml:space="preserve">{package['description']}</Description>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="{package['engines']['vscode']}"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace"/>
    </Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
    <Asset Type="Microsoft.VisualStudio.Services.Content.License" Path="extension/LICENSE.txt" Addressable="true"/>
  </Assets>
</PackageManifest>
"""
    content_types = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".txt" ContentType="text/plain"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
</Types>
"""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("extension.vsixmanifest", manifest)
        archive.writestr("[Content_Types].xml", content_types)
        for name in ("extension.js", "package.json"):
            source = HERE / "extension" / name
            archive.write(source, f"extension/{source.name}")
        archive.write(HERE.parents[1] / "LICENSE", "extension/LICENSE.txt")
    print("Runfern extension", identity, package["version"])
    return buffer.getvalue()


def write_file(path, source, permissions="0644"):
    return {"path": path, "permissions": permissions, "encoding": "b64",
            "content": base64.b64encode(source.read_bytes()).decode()}


def runfern_files():
    """The files every image gets: agent, its service, editor defaults, and the Runfern extension."""
    return [write_file("/usr/lib/runfern/runfern-agent.py", FILES / "runfern-agent.py", "0755"),
             write_file("/usr/lib/runfern/image-evidence.py", HERE / "image_evidence.py", "0755"),
             write_file("/usr/lib/runfern/LICENSE.txt", HERE.parents[1] / "LICENSE"),
             write_file("/etc/systemd/system/runfern-agent.service", FILES / "runfern-agent.service"),
             write_file("/usr/lib/runfern/vscode-machine-settings.json", FILES / "vscode-machine-settings.json"),
             {"path": "/usr/lib/runfern/runfern.vsix", "permissions": "0644", "encoding": "b64",
              "content": base64.b64encode(runfern_extension_vsix()).decode()}]


def user_data(base):
    flavor = FLAVORS[base["flavor"]]
    files = runfern_files()
    if base["flavor"] == "apt":
        files.append({"path": "/etc/initramfs-tools/modules", "append": True, "content": "\n".join(BOOT_MODULES) + "\n"})
        files.append({"path": "/etc/initramfs-tools/conf.d/runfern", "content": "MODULES=dep\nCOMPRESS=xz\n"})
    files.append({"path": "/usr/lib/runfern/editor.json", "content": json.dumps(EDITOR)})

    # The VM boots kernel and initramfs directly, from the newest kernel installed. Debian and
    # Ubuntu build the initramfs with initramfs-tools, the others with dracut.
    if base["flavor"] == "apt":
        initramfs = """if [ -f "/boot/initrd.img-$VERSION" ]; then
    update-initramfs -u -k "$VERSION"
else
    update-initramfs -c -k "$VERSION"
fi
cp "/boot/initrd.img-$VERSION" /tmp/out/initrd.img"""
    else:
        initramfs = f"""dracut --force --no-hostonly --add-drivers "{' '.join(BOOT_MODULES)}" --kver "$VERSION" /tmp/out/initrd.img"""

    script = f"""
set -eux
# cloud-init carries on when installing the packages fails; installing them again here stops the
# build instead (and has nothing to do once they are installed).
{flavor['install_packages'].format(packages=' '.join(flavor['packages']))}
{flavor['install_kernel'].format(kernel=base['kernel'])}
# Editor
mkdir -p /opt/openvscode-server
curl -fsSL --retry 3 '{EDITOR["url"]}' -o /tmp/editor.tar.gz
echo '{EDITOR["sha256"]}  /tmp/editor.tar.gz' | sha256sum -c -
tar -xzf /tmp/editor.tar.gz -C /opt/openvscode-server --strip-components=1
rm /tmp/editor.tar.gz
# The project folder, served by the app over 9p (see NinePServer.swift)
mkdir -p /workspace
# Verified toolchain archives and extensions from the app, read-only (see PackageLibrary.swift)
mkdir -p /mnt/runfern-packages /opt/runfern
echo 'packages /mnt/runfern-packages 9p trans=virtio,version=9p2000.L,msize=524288,ro,nofail,x-systemd.automount 0 0' >> /etc/fstab
# Editor defaults tuned for interpreted execution: no background polling, indexing, or telemetry.
install -d -o runfern -g runfern /home/runfern/.openvscode-server /home/runfern/.openvscode-server/data /home/runfern/.openvscode-server/data/Machine
install -o runfern -g runfern -m 0644 /usr/lib/runfern/vscode-machine-settings.json /home/runfern/.openvscode-server/data/Machine/settings.json
# Runfern's own editor extension: back to the app, preview (see Tools/GuestImage/extension).
runuser -u runfern -- /opt/openvscode-server/bin/openvscode-server --install-extension /usr/lib/runfern/runfern.vsix
systemctl enable runfern-agent.service
# Cloud provisioning and automatic updates are not needed anymore.
touch /etc/cloud/cloud-init.disabled
{flavor['quiet']}
mkdir -p /tmp/out
VERSION=$(ls /lib/modules | grep -v -- '-cloud-' | sort -V | tail -1)
python3 /usr/lib/runfern/image-evidence.py slim --manager {base["flavor"]} --kernel "$VERSION"
for KERNEL in "/boot/vmlinuz-$VERSION" "/boot/Image-$VERSION" "/lib/modules/$VERSION/vmlinuz"; do
    [ -f "$KERNEL" ] && break
done
cp "$KERNEL" /tmp/out/vmlinuz
{initramfs}
# Root by UUID; on btrfs (Fedora) also the subvolume. SELinux labels don't apply to the 9p shares.
ROOTFLAGS=""
SUBVOLUME=$(findmnt -no FSROOT / | sed 's|^/||')
[ -n "$SUBVOLUME" ] && [ "$(findmnt -no FSTYPE /)" = btrfs ] && ROOTFLAGS="rootflags=subvol=$SUBVOLUME"
echo "root=UUID=$(findmnt -no UUID /) $ROOTFLAGS ro console=ttyAMA0 quiet loglevel=3 selinux=0" > /tmp/out/cmdline.txt
echo "$VERSION" > /tmp/out/kernel-version.txt
python3 /usr/lib/runfern/image-evidence.py collect --manager {base["flavor"]} --output /tmp/out/evidence
{flavor['clean']}
rm -rf /var/log/*.log
if command -v cloud-init >/dev/null; then cloud-init clean --logs; fi
# The boot files last: the host takes them as the sign that every step succeeded.
tar -cf /dev/vdc -C /tmp/out .
sync
rm -rf /tmp/out
# Frees the deleted files' blocks in disk.qcow2 too (discard=unmap), so they stay out of the bundle.
fstrim -av || true
poweroff
"""
    files.append({"path": "/usr/lib/runfern/customize.sh", "permissions": "0755", "content": script})

    config = {
        "users": [{"name": "runfern", "uid": 501, "shell": "/bin/bash", "lock_passwd": True,
                   "sudo": "ALL=(ALL) NOPASSWD:ALL"}],
        "package_update": True,
        "package_upgrade": True,
        "packages": flavor["packages"],
        "write_files": files,
        # The host waits for the VM to stop, so a failed customization powers off right away
        # instead of after the timeout (hours with tcg); the missing boot files report it.
        "runcmd": [["/bin/bash", "-c",
                   "systemd-run --unit=runfern-customize --no-block "
                   "--property=StandardOutput=journal+console --property=StandardError=journal+console "
                   "/bin/bash -c '/bin/bash /usr/lib/runfern/customize.sh || poweroff' || poweroff"]],
    }
    # JSON is valid YAML, which keeps this script free of extra dependencies.
    return "#cloud-config\n" + json.dumps(config, indent=1)


def bootable_kernel(path):
    """The kernel in a form QEMU's -kernel loads without firmware: a plain arm64 Image, gzip-compressed
    if that's smaller. Some distributions wrap it in an EFI program (Ubuntu's device-tree loader, or a
    compressed "zboot" image); the Image inside is extracted then."""
    data = path.read_bytes()

    def is_image(blob):
        return len(blob) > 0x40 and blob[0x38:0x3c] == b"ARMd"

    if is_image(data):
        return data
    payload = data
    if data[:2] == b"MZ":
        pe = struct.unpack_from("<I", data, 0x3c)[0]
        count, optional = struct.unpack_from("<H", data, pe + 6)[0], struct.unpack_from("<H", data, pe + 20)[0]
        for index in range(count):
            name, _, _, size, offset = struct.unpack_from("<8sIIII", data, pe + 24 + optional + 40 * index)
            if name.rstrip(b"\0") == b".linux":
                payload = data[offset:offset + size]
    if payload[4:8] == b"zimg":  # EFI zboot: offset and size of the compressed Image follow the magic
        offset, size = struct.unpack_from("<II", payload, 8)
        payload = payload[offset:offset + size]
    for magic, command in ((b"\x28\xb5\x2f\xfd", ["zstd", "-dcq"]), (b"\x1f\x8b\x08", ["gzip", "-dc"])):
        start = payload.find(magic)
        if start >= 0:
            # Trailing data after the stream is ignored; only a complete Image counts.
            image = subprocess.run(command, input=payload[start:], capture_output=True).stdout
            if is_image(image):
                return gzip.compress(image, compresslevel=9)
    sys.exit(f"{path} is not a kernel QEMU can boot directly")


def build_root():
    return pathlib.Path(os.environ.get("RUNFERN_IMAGE_BUILD_ROOT", HERE / "build")).resolve()


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in BASES:
        sys.exit("Usage: build_image.py " + "|".join(BASES))
    image_id = sys.argv[1]
    base = BASES[image_id]
    started = int(time.time())
    expected_sources = {name: image_evidence.digest(HERE.parents[1] / name)
                        for name in image_evidence.RUNFERN_SOURCES}
    source_revision = {
        "commit": image_evidence.command("git", "rev-parse", "HEAD", cwd=HERE.parents[1]),
        "dirty": bool(image_evidence.command("git", "status", "--porcelain", "--",
                                            *image_evidence.RUNFERN_SOURCES, cwd=HERE.parents[1]))}
    require_programs()
    accel = accelerator()
    timeout = build_timeout(accel)
    firmware, firmware_variables = efi_firmware()
    iso_tool = seed_iso_tool()
    print(f"Accelerator: {accel}" + (" (emulated, this takes hours)" if accel == "tcg" else ""), flush=True)

    build = build_root() / image_id
    work = build / "work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    archive = build / f"{image_id}.runfernimage"
    # Results of an earlier build must not survive a failed one and get published instead.
    for stale in (archive, build / f"{image_id}.sha256", build / f"{image_id}.json",
                  build / f"{image_id}.evidence.json", build / f"{image_id}.licenses.tar",
                  *build.glob(f"{image_id}.sources-*.tar")):
        stale.unlink(missing_ok=True)

    url = base["url"]
    cloud_image = build_root() / pathlib.Path(url).name
    if not cloud_image.exists():
        run("curl", "-fL", "--retry", "3", "-o", cloud_image, url)
    algorithm = "sha512" if "sha512" in base else "sha256"
    image_evidence.verify_digest(cloud_image, base[algorithm], algorithm)
    ide_version = EDITOR["version"]
    print("openvscode-server", ide_version)

    disk = work / "disk.qcow2"
    run("qemu-img", "convert", "-O", "qcow2", cloud_image, disk)
    run("qemu-img", "resize", disk, DISK_SIZE)

    seed = work / "seed"
    seed.mkdir()
    (seed / "meta-data").write_text(f"instance-id: runfern-{image_id}\nlocal-hostname: runfern\n")
    (seed / "user-data").write_text(user_data(base))
    run(*seed_iso_command(iso_tool, seed, work / "seed.iso"))
    out = work / "out.raw"
    run("qemu-img", "create", "-f", "raw", out, "8G")

    console = work / "console.log"
    variables = work / "efi-vars.fd"
    # copyfile, not copy: the template may be read-only, but the VM writes to its copy.
    shutil.copyfile(firmware_variables, variables)
    try:
        # romfile= leaves out the NIC's iPXE boot ROM: the VM boots from disk, the firmware has its
        # own virtio-net driver, and Debian/Ubuntu only recommend the package with the ROM (ipxe-qemu).
        run("qemu-system-aarch64", "-machine", "virt", *vm_cpu_arguments(accel), "-m", "4096",
            "-nographic", "-serial", f"file:{console}", "-monitor", "none",
            "-drive", f"if=pflash,format=raw,readonly=on,file={firmware}",
            "-drive", f"if=pflash,format=raw,file={variables}",
            # discard=unmap: blocks the guest trims (fstrim) leave disk.qcow2 instead of keeping
            # deleted files' data, which qemu-img convert would copy into the bundle.
            "-drive", f"if=virtio,format=qcow2,discard=unmap,file={disk}",
            "-drive", f"if=virtio,format=raw,readonly=on,file={work / 'seed.iso'}",
            "-drive", f"if=virtio,format=raw,file={out}",
            "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0,romfile=", timeout=timeout)
    except subprocess.TimeoutExpired:
        print(console_tail(console), file=sys.stderr)
        sys.exit(f"The customization VM didn't finish within {timeout} s (RUNFERN_BUILD_TIMEOUT); see {console}")
    except subprocess.CalledProcessError as error:
        print(console_tail(console), file=sys.stderr)
        sys.exit(f"QEMU failed with exit status {error.returncode}; see its error message and {console}")

    extracted = work / "boot"
    extracted.mkdir()
    run("tar", "-xf", out, "-C", extracted)
    if not (extracted / "vmlinuz").exists():
        print(console_tail(console), file=sys.stderr)
        sys.exit(f"Customization failed; see {console}")

    bundle = build / "bundle"
    shutil.rmtree(bundle, ignore_errors=True)
    bundle.mkdir()
    run("qemu-img", "convert", "-O", "qcow2", "-c", disk, bundle / "disk.qcow2")
    (bundle / "vmlinuz").write_bytes(bootable_kernel(extracted / "vmlinuz"))
    shutil.copy(extracted / "initrd.img", bundle / "initrd.img")
    manifest = {"format": 1, "kernelCommandLine": (extracted / "cmdline.txt").read_text().strip(),
                "agentProtocolVersion": AGENT_PROTOCOL_VERSION,
                # Environments remember the build they were created on and refuse a replaced base.
                "buildID": str(uuid.uuid4()),
                "kernelVersion": (extracted / "kernel-version.txt").read_text().strip(),
                "ideVersion": ide_version}
    (bundle / "image.json").write_text(json.dumps(manifest, indent=2) + "\n")

    command, environment = archive_command(archive, bundle, started)
    run(*command, env=environment)
    size = release_size(archive)
    digest = sha256(archive)
    (build / f"{image_id}.sha256").write_text(digest + "\n")
    summary = json.dumps({"id": image_id, "sizeBytes": size, "sha256": digest}, indent=2)
    (build / f"{image_id}.json").write_text(summary + "\n")
    for name, expected in expected_sources.items():
        image_evidence.verify_digest(HERE.parents[1] / name, expected)
    image_evidence.package(build, image_id, extracted / "evidence", base, EDITOR, source_revision)
    image_evidence.verify(build, image_id)
    print(summary)


if __name__ == "__main__":
    main()
