#!/usr/bin/env python3
"""Builds a Runfern Linux base image bundle (see ImageBundle.swift) on a Mac.

The official cloud image of the distribution is customized once in a hardware-accelerated
VM (Homebrew QEMU with HVF) via cloud-init: GuestAgent, openvscode-server, the Runfern extension,
the generic kernel with 9p support, and the /workspace mount. The VM writes kernel, initrd,
and kernel command line to an extra raw disk as a tar stream, then powers off.

Usage: build_image.py debian-12-arm64|ubuntu-24.04-arm64

Output in Tools/GuestImage/build/<id>/:
    <id>.runfernimage   ustar bundle to publish
    <id>.sha256         checksum for the catalog's ImageSource
"""
import base64
import io
import json
import pathlib
import shutil
import subprocess
import sys
import urllib.request
import uuid
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
FILES = HERE / "files"

BASES = {
    "debian-12-arm64": {
        "url": "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2",
        "kernel_package": "linux-image-arm64",
    },
    "ubuntu-24.04-arm64": {
        "url": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img",
        "kernel_package": "linux-image-generic",
    },
}
DISK_SIZE = "16G"
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


def user_data(base, ide_url):
    files = [write_file("/usr/lib/runfern/runfern-agent.py", FILES / "runfern-agent.py", "0755"),
             write_file("/etc/systemd/system/runfern-agent.service", FILES / "runfern-agent.service"),
             write_file("/usr/lib/runfern/vscode-machine-settings.json", FILES / "vscode-machine-settings.json"),
             {"path": "/usr/lib/runfern/runfern.vsix", "permissions": "0644", "encoding": "b64",
              "content": base64.b64encode(runfern_extension_vsix()).decode()}]
    files.append({"path": "/etc/initramfs-tools/modules", "append": True,
                  "content": "virtio_pci\nvirtio_blk\nvirtio_net\nvirtio_console\n9p\n9pnet_virtio\n"})

    script = f"""
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends {base['kernel_package']}
# Editor
mkdir -p /opt/openvscode-server
curl -fsSL '{ide_url}' | tar -xz -C /opt/openvscode-server --strip-components=1
# Project folder shared by the app over 9p
mkdir -p /workspace
# All working copies of the app; the agent binds the active project to /workspace.
mkdir -p /mnt/workspaces
echo 'workspaces /mnt/workspaces 9p trans=virtio,version=9p2000.L,msize=524288,access=any,nofail,x-systemd.automount 0 0' >> /etc/fstab
# Verified toolchain archives and extensions from the app, read-only (see PackageLibrary.swift)
mkdir -p /mnt/runfern-packages /opt/runfern
echo 'packages /mnt/runfern-packages 9p trans=virtio,version=9p2000.L,msize=524288,ro,nofail,x-systemd.automount 0 0' >> /etc/fstab
# Editor defaults tuned for interpreted execution: no background polling, indexing, or telemetry.
install -d -o runfern -g runfern /home/runfern/.openvscode-server /home/runfern/.openvscode-server/data /home/runfern/.openvscode-server/data/Machine
install -o runfern -g runfern -m 0644 /usr/lib/runfern/vscode-machine-settings.json /home/runfern/.openvscode-server/data/Machine/settings.json
# Runfern's own editor extension: back to the app, preview (see Tools/GuestImage/extension).
runuser -u runfern -- /opt/openvscode-server/bin/openvscode-server --install-extension /usr/lib/runfern/runfern.vsix
systemctl enable runfern-agent.service
# The VM boots its kernel directly; firmware, bootloader, and cloud-init are not needed anymore.
touch /etc/cloud/cloud-init.disabled
systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer || true
# The cloud kernel flavor lacks 9p; boot the generic one.
KERNEL=$(ls /boot/vmlinuz-* | grep -v -- '-cloud-' | sort -V | tail -1)
VERSION=${{KERNEL#/boot/vmlinuz-}}
update-initramfs -c -k "$VERSION" || update-initramfs -u -k "$VERSION"
mkdir -p /tmp/out
cp "$KERNEL" /tmp/out/vmlinuz
cp "/boot/initrd.img-$VERSION" /tmp/out/initrd.img
echo "root=UUID=$(findmnt -no UUID /) ro console=ttyAMA0 quiet loglevel=3" > /tmp/out/cmdline.txt
echo "$VERSION" > /tmp/out/kernel-version.txt
tar -cf /dev/vdc -C /tmp/out .
sync
apt-get clean
rm -rf /var/lib/apt/lists/* /var/log/*.log /tmp/out
cloud-init clean --logs || true
fstrim -av || true
poweroff
"""
    files.append({"path": "/usr/lib/runfern/customize.sh", "permissions": "0755", "content": script})

    config = {
        "users": [{"name": "runfern", "uid": 501, "shell": "/bin/bash", "lock_passwd": True,
                   "sudo": "ALL=(ALL) NOPASSWD:ALL"}],
        "package_update": True,
        "packages": ["python3", "git", "curl", "ca-certificates", "build-essential", "openssh-client", "unzip",
                     "xz-utils", "procps", "less", "nano"],
        "write_files": files,
        "runcmd": [["/bin/bash", "/usr/lib/runfern/customize.sh"]],
    }
    # JSON is valid YAML, which keeps this script free of extra dependencies.
    return "#cloud-config\n" + json.dumps(config, indent=1)


def main():
    image_id = sys.argv[1] if len(sys.argv) > 1 else "debian-12-arm64"
    base = BASES[image_id]
    build = HERE / "build" / image_id
    work = build / "work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    cloud_image = HERE / "build" / pathlib.Path(base["url"]).name
    if not cloud_image.exists():
        run("curl", "-fL", "-o", cloud_image, base["url"])

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
    shutil.copy(extracted / "vmlinuz", bundle / "vmlinuz")
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
