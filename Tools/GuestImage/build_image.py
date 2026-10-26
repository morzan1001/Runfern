#!/usr/bin/env python3
"""Builds a Runfern Linux base image bundle (see ImageBundle.swift) on a Mac.

The official cloud image of the distribution is customized once in a hardware-accelerated
VM (Homebrew QEMU with HVF) via cloud-init: GuestAgent, openvscode-server, the Runfern extension,
a kernel with 9p support, the libraries the catalog's toolchains need, and the /workspace mount.
Distributions differ only in their package manager (FLAVORS). The VM writes kernel, initrd,
and kernel command line to an extra raw disk as a tar stream, then powers off.

Usage: build_image.py <id>        ids: see BASES (debian-12-arm64, fedora-44-arm64, ...)

Output in Tools/GuestImage/build/<id>/:
    <id>.runfernimage   ustar bundle to publish
    <id>.sha256         checksum for the catalog's ImageSource
"""
import base64
import gzip
import io
import json
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import urllib.request
import uuid
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
FILES = HERE / "files"

# Official cloud images. A `url` ending in "/" is a directory whose newest matching file is used.
BASES = {
    "debian-12-arm64": {"flavor": "apt", "kernel": "linux-image-arm64",
                        "url": "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2"},
    "debian-13-arm64": {"flavor": "apt", "kernel": "linux-image-arm64",
                        "url": "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2"},
    "ubuntu-24.04-arm64": {"flavor": "apt", "kernel": "linux-image-generic",
                           "url": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"},
    "ubuntu-26.04-arm64": {"flavor": "apt", "kernel": "linux-image-generic",
                           "url": "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-arm64.img"},
    "fedora-44-arm64": {"flavor": "dnf", "kernel": "kernel-core kernel-modules",
                        "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/",
                        "pattern": r"Fedora-Cloud-Base-Generic-44-[\d.]+\.aarch64\.qcow2"},
    "opensuse-tumbleweed-arm64": {"flavor": "zypper", "kernel": "kernel-default",
                                  "url": "https://download.opensuse.org/ports/aarch64/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.aarch64-Cloud.qcow2"},
}

# What differs between package managers: packages (tools, and the libraries Swift, .NET, Flutter,
# and native modules link against), installing the kernel, and building the initramfs.
COMMON_TOOLS = ["python3", "git", "curl", "ca-certificates", "unzip", "zip", "less", "nano", "tar"]
FLAVORS = {
    "apt": {
        "packages": COMMON_TOOLS + ["build-essential", "openssh-client", "xz-utils", "procps", "pkg-config", "tzdata",
                                    "libicu-dev", "libcurl4-openssl-dev", "libxml2-dev", "libncurses-dev",
                                    "libsqlite3-dev", "zlib1g-dev", "libpython3-dev", "libedit2"],
        "install_kernel": "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {kernel}",
        "quiet": "systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer || true",
        "clean": "apt-get clean; rm -rf /var/lib/apt/lists/*",
    },
    "dnf": {
        "packages": COMMON_TOOLS + ["gcc", "gcc-c++", "make", "openssh-clients", "xz", "procps-ng", "pkgconf", "tzdata",
                                    "libicu", "libcurl-devel", "libxml2-devel", "ncurses-devel", "sqlite-devel",
                                    "zlib-devel", "python3-devel", "libedit", "dracut"],
        "install_kernel": "dnf -y install {kernel}",
        "quiet": "systemctl disable --now dnf-makecache.timer || true",
        "clean": "dnf clean all",
    },
    "zypper": {
        "packages": COMMON_TOOLS + ["gcc", "gcc-c++", "make", "openssh-clients", "xz", "procps", "pkg-config", "timezone",
                                    "libicu-devel", "libcurl-devel", "libxml2-devel", "ncurses-devel", "sqlite3-devel",
                                    "zlib-devel", "python3-devel", "libedit0", "dracut"],
        "install_kernel": "zypper --non-interactive install --no-recommends {kernel}",
        "quiet": "systemctl disable --now transactional-update.timer || true",
        "clean": "zypper clean --all",
    },
}
DISK_SIZE = "16G"
# Drivers the initramfs needs to find the disk and the shares before the root file system is up.
BOOT_MODULES = ["virtio_pci", "virtio_blk", "virtio_net", "virtio_console", "9p", "9pnet_virtio"]
AGENT_PROTOCOL_VERSION = 1


def run(*command, **options):
    print("+", " ".join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **options)


def latest_openvscode_server():
    request = urllib.request.Request("https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest",
                                     headers={"Accept": "application/vnd.github+json"})
    release = json.load(urllib.request.urlopen(request))
    for asset in release["assets"]:
        if asset["name"].endswith("linux-arm64.tar.gz"):
            return release["tag_name"], asset["browser_download_url"]
    sys.exit("No arm64 build of openvscode-server found")


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
  </Assets>
</PackageManifest>
"""
    content_types = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
</Types>
"""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("extension.vsixmanifest", manifest)
        archive.writestr("[Content_Types].xml", content_types)
        for source in sorted((HERE / "extension").iterdir()):
            archive.write(source, f"extension/{source.name}")
    print("Runfern extension", identity, package["version"])
    return buffer.getvalue()


def write_file(path, source, permissions="0644"):
    return {"path": path, "permissions": permissions, "encoding": "b64",
            "content": base64.b64encode(source.read_bytes()).decode()}


def runfern_files():
    """The files every image gets: agent, its service, editor defaults, and the Runfern extension."""
    return [write_file("/usr/lib/runfern/runfern-agent.py", FILES / "runfern-agent.py", "0755"),
             write_file("/etc/systemd/system/runfern-agent.service", FILES / "runfern-agent.service"),
             write_file("/usr/lib/runfern/vscode-machine-settings.json", FILES / "vscode-machine-settings.json"),
             {"path": "/usr/lib/runfern/runfern.vsix", "permissions": "0644", "encoding": "b64",
              "content": base64.b64encode(runfern_extension_vsix()).decode()}]


def user_data(base, ide_url):
    flavor = FLAVORS[base["flavor"]]
    files = runfern_files()
    if base["flavor"] == "apt":
        files.append({"path": "/etc/initramfs-tools/modules", "append": True, "content": "\n".join(BOOT_MODULES) + "\n"})

    # The VM boots kernel and initramfs directly, from the newest kernel installed. Debian and
    # Ubuntu build the initramfs with initramfs-tools, the others with dracut.
    if base["flavor"] == "apt":
        initramfs = """update-initramfs -c -k "$VERSION" || update-initramfs -u -k "$VERSION"
cp "/boot/initrd.img-$VERSION" /tmp/out/initrd.img"""
    else:
        initramfs = f"""dracut --force --no-hostonly --add-drivers "{' '.join(BOOT_MODULES)}" --kver "$VERSION" /tmp/out/initrd.img"""

    script = f"""
set -eux
{flavor['install_kernel'].format(kernel=base['kernel'])}
# Editor
mkdir -p /opt/openvscode-server
curl -fsSL '{ide_url}' | tar -xz -C /opt/openvscode-server --strip-components=1
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
# Firmware, bootloader, cloud-init, and automatic updates are not needed anymore.
touch /etc/cloud/cloud-init.disabled
{flavor['quiet']}
mkdir -p /tmp/out
VERSION=$(ls /lib/modules | grep -v -- '-cloud-' | sort -V | tail -1)
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
tar -cf /dev/vdc -C /tmp/out .
sync
{flavor['clean']}
rm -rf /var/log/*.log /tmp/out
cloud-init clean --logs || true
fstrim -av || true
poweroff
"""
    files.append({"path": "/usr/lib/runfern/customize.sh", "permissions": "0755", "content": script})

    config = {
        "users": [{"name": "runfern", "uid": 501, "shell": "/bin/bash", "lock_passwd": True,
                   "sudo": "ALL=(ALL) NOPASSWD:ALL"}],
        "package_update": True,
        "packages": flavor["packages"],
        "write_files": files,
        "runcmd": [["/bin/bash", "/usr/lib/runfern/customize.sh"]],
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


def cloud_image_url(base):
    """The image's address; for a directory the newest file matching the base's pattern."""
    if not base["url"].endswith("/"):
        return base["url"]
    listing = urllib.request.urlopen(base["url"]).read().decode()
    names = sorted(set(re.findall(base["pattern"], listing)))
    if not names:
        sys.exit(f"No image matching {base['pattern']} in {base['url']}")
    return base["url"] + names[-1]


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in BASES:
        sys.exit("Usage: build_image.py " + "|".join(BASES))
    image_id = sys.argv[1]
    base = BASES[image_id]
    build = HERE / "build" / image_id
    work = build / "work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    url = cloud_image_url(base)
    cloud_image = HERE / "build" / pathlib.Path(url).name
    if not cloud_image.exists():
        run("curl", "-fL", "-o", cloud_image, url)

    ide_version, ide_url = latest_openvscode_server()
    print("openvscode-server", ide_version)

    disk = work / "disk.qcow2"
    run("qemu-img", "convert", "-O", "qcow2", cloud_image, disk)
    run("qemu-img", "resize", disk, DISK_SIZE)

    seed = work / "seed"
    seed.mkdir()
    (seed / "meta-data").write_text(f"instance-id: runfern-{image_id}\nlocal-hostname: runfern\n")
    (seed / "user-data").write_text(user_data(base, ide_url))
    run("hdiutil", "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata",
        "-o", work / "seed.iso", seed)
    out = work / "out.raw"
    run("qemu-img", "create", "-f", "raw", out, "512M")

    share = pathlib.Path(subprocess.check_output(["brew", "--prefix", "qemu"], text=True).strip()) / "share/qemu"
    variables = work / "efi-vars.fd"
    shutil.copy(share / "edk2-arm-vars.fd", variables)
    run("qemu-system-aarch64", "-machine", "virt", "-accel", "hvf", "-cpu", "host", "-smp", "4", "-m", "4096",
        "-nographic", "-serial", f"file:{work / 'console.log'}", "-monitor", "none",
        "-drive", f"if=pflash,format=raw,readonly=on,file={share / 'edk2-aarch64-code.fd'}",
        "-drive", f"if=pflash,format=raw,file={variables}",
        "-drive", f"if=virtio,format=qcow2,file={disk}",
        "-drive", f"if=virtio,format=raw,readonly=on,file={work / 'seed.iso'}",
        "-drive", f"if=virtio,format=raw,file={out}",
        "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0", timeout=3600)

    extracted = work / "boot"
    extracted.mkdir()
    run("tar", "-xf", out, "-C", extracted)
    if not (extracted / "vmlinuz").exists():
        sys.exit(f"Customization failed; see {work / 'console.log'}")

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

    archive = build / f"{image_id}.runfernimage"
    run("tar", "--format", "ustar", "-cf", archive, "-C", bundle, "image.json", "disk.qcow2", "vmlinuz", "initrd.img",
        env={"COPYFILE_DISABLE": "1", "PATH": "/usr/bin:/bin"})
    digest = subprocess.check_output(["shasum", "-a", "256", archive], text=True).split()[0]
    (build / f"{image_id}.sha256").write_text(digest + "\n")
    print(json.dumps({"id": image_id, "sizeBytes": archive.stat().st_size, "sha256": digest}, indent=2))


if __name__ == "__main__":
    main()
