#!/usr/bin/env python3
"""Collect and verify licenses and corresponding sources for one Linux image."""
import argparse
import fnmatch
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
MAX_ASSET = 2 << 30
SOURCE_PART_SIZE = 1 << 30
RUNFERN_SOURCES = ["LICENSE", "Version.xcconfig", "Tools/GuestImage/build_image.py",
                   "Tools/GuestImage/image_evidence.py", "Tools/GuestImage/extension/extension.js",
                   "Tools/GuestImage/extension/package.json", "Tools/GuestImage/files/runfern-agent.py",
                   "Tools/GuestImage/files/runfern-agent.service", "Tools/GuestImage/files/vscode-machine-settings.json"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path, algorithm="sha256"):
    value = hashlib.new(algorithm)
    with pathlib.Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 << 20), b""):
            value.update(chunk)
    return value.hexdigest()


def verify_digest(path, expected, algorithm="sha256"):
    require(digest(path, algorithm) == expected, f"Checksum mismatch: {path}")


def command(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def write_json(path, value):
    pathlib.Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def safe_path(name):
    path = pathlib.PurePosixPath(name)
    require(isinstance(name, str) and name and not path.is_absolute()
            and ".." not in path.parts and str(path) == name, f"Unsafe evidence path: {name}")
    return name


def fetch(url, target, expected):
    require(url.startswith("https://"), f"Source download must use HTTPS: {url}")
    target = pathlib.Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        temporary = target.with_name(target.name + ".download")
        try:
            with urllib.request.urlopen(url, timeout=120) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            verify_digest(temporary, expected)
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    verify_digest(target, expected)


def apt_packages():
    fields = "${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\t${Architecture}\t${db:Status-Status}\n"
    packages = []
    for line in command("dpkg-query", "-W", "-f", fields).splitlines():
        name, version, source, source_version, architecture, status = line.split("\t")
        if status == "installed":
            packages.append({"name": name, "version": version, "architecture": architecture,
                             "source": source or name.split(":")[0], "sourceVersion": source_version or version})
    return sorted(packages, key=lambda p: p["name"])


def rpm_packages():
    fields = "%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SOURCERPM}\t%{LICENSE}\n"
    return sorted([dict(zip(("name", "version", "architecture", "sourceRPM", "license"), line.split("\t")))
                   for line in command("rpm", "-qa", "--qf", fields).splitlines()], key=lambda p: p["name"])


def slim(manager, kernel):
    # Some cloud images mark their boot chain essential; retain it rather than bypass APT safeguards.
    boot_only = {"cloud-init", "cloud-guest-utils", "cloud-initramfs-copymods", "cloud-initramfs-dyn-netconf",
                 "snapd", "fwupd", "ubuntu-advantage-tools", "ubuntu-pro-client", "ubuntu-pro-client-l10n",
                 "openssh-server"}
    packages = apt_packages() if manager == "apt" else rpm_packages()
    kernel_sources = {(package["source"], package["sourceVersion"]) for package in packages
                      if manager == "apt"
                      and package["name"].startswith(("linux-image-", "linux-modules-"))
                      and package["name"].endswith(kernel)}
    remove = []
    for package in packages:
        name = package["name"].split(":")[0]
        old_kernel = (manager == "apt" and re.match(r"linux-(image|modules)(-extra)?-[0-9]", name)
                      and not name.endswith(kernel))
        if manager == "apt" and re.match(r"linux-(headers|tools|cloud-tools)-[0-9]", name):
            old_kernel = (package["source"], package["sourceVersion"]) not in kernel_sources
        if manager == "dnf" and name in {"kernel", "kernel-core", "kernel-modules", "kernel-modules-core"}:
            old_kernel = package["version"].split(":", 1)[-1] + "." + package["architecture"] != kernel
        if name in boot_only or name == "linux-image-cloud-arm64" or fnmatch.fnmatch(name, "*firmware*") or old_kernel:
            remove.append(name if manager == "apt" else
                          f"{name}-{package['version'].split(':', 1)[-1]}.{package['architecture']}")
    if manager == "apt":
        keep = [p["name"] for p in packages if p["name"].startswith(("linux-image-", "linux-modules-"))
                and p["name"].endswith(kernel)]
        require(keep, f"No installed package provides kernel {kernel}")
        subprocess.run(["apt-mark", "manual", *keep], check=True)
        running = command("uname", "-r")
        for name in remove:
            if name.startswith("linux-image-") and name.endswith(running):
                # Only the disposable build VM uses this kernel; the final boot target is retained.
                subprocess.run(["debconf-set-selections"],
                               input=f"{name} {name}/prerm/removing-running-kernel boolean false\n",
                               text=True, check=True)
    if remove:
        subprocess.run((["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "purge", "-y"]
                        if manager == "apt" else ["dnf", "remove", "-y"])
                       + remove, check=True)
    require(pathlib.Path("/lib/modules", kernel).is_dir(), "Image slimming removed the selected kernel")


def enable_apt_sources():
    directory = pathlib.Path("/etc/apt")
    changed = False
    for path in [directory / "sources.list", *sorted((directory / "sources.list.d").glob("*"))]:
        if not path.is_file() or path.suffix not in (".list", ".sources"):
            continue
        text = path.read_text()
        if path.suffix == ".sources":
            text = re.sub(r"(?m)^Types:\s*deb\s*$", "Types: deb deb-src", text)
        else:
            lines = text.splitlines()
            for line in list(lines):
                if re.match(r"^\s*deb\s", line):
                    source = re.sub(r"^(\s*)deb(\s)", r"\1deb-src\2", line)
                    if source not in lines:
                        lines.append(source)
            text = "\n".join(lines) + "\n"
        text = text.replace("http://", "https://")
        if text != path.read_text():
            path.write_text(text)
            changed = True
    if changed:
        subprocess.run(["apt-get", "update"], check=True)


def deb_source_fields(text):
    fields = {}
    current = None
    for line in text.splitlines():
        if line == "-----BEGIN PGP SIGNATURE-----":
            break
        if line.startswith(" ") and current:
            fields[current] += ("\n" if fields[current] else "") + line.strip()
        elif re.match(r"^[A-Za-z][A-Za-z0-9-]*:", line):
            current, value = line.split(":", 1)
            fields[current] = value.strip()
        else:
            current = None
    return fields


def source_files(root):
    return {path.relative_to(root).as_posix(): digest(path)
            for path in sorted(root.rglob("*")) if path.is_file()}


def copy_notices(package, manager, output, providers):
    if manager == "apt":
        paths = command("dpkg-query", "-L", package["name"]).splitlines()
        selected = [pathlib.Path(p) for p in paths if p.endswith("/copyright")]
        selected.append(pathlib.Path("/usr/share/doc", package["name"].split(":")[0], "copyright"))
    else:
        paths = command("rpm", "-q", "--licensefiles", package["name"]).splitlines()
        selected = [pathlib.Path(p) for p in paths]
        if not any(path.is_file() for path in selected):
            selected = providers.get(package["sourceRPM"], [])
    selected = sorted({p for p in selected if p.is_file()})
    require(selected, f"No installed copyright/license document for {package['name']}")
    key = hashlib.sha256((package["name"] + "=" + package["version"]).encode()).hexdigest()[:20]
    result = []
    for index, path in enumerate(selected):
        data = path.read_bytes()
        require(data.strip() and b"\0" not in data, f"Unreadable legal document: {path}")
        target = output / "notices" / key / f"{index:03d}.txt"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        result.append({"file": target.relative_to(output).as_posix(), "installedPath": str(path)})
    return result


def collect(manager, output):
    output.mkdir(parents=True, exist_ok=False)
    packages = apt_packages() if manager == "apt" else rpm_packages()
    require(packages, "Empty installed package inventory")
    providers = {}
    if manager == "apt":
        enable_apt_sources()
    else:
        for package in packages:
            if package["name"] != "gpg-pubkey":
                paths = command("rpm", "-q", "--licensefiles", package["name"]).splitlines()
                providers.setdefault(package["sourceRPM"], []).extend(pathlib.Path(p) for p in paths)
    sources = {}
    for package in packages:
        if manager == "dnf" and package["name"] == "gpg-pubkey":
            package["kind"] = "distribution-signing-key"
            continue
        package["notices"] = copy_notices(package, manager, output, providers)
        identity = (package["source"] + "=" + package["sourceVersion"] if manager == "apt"
                    else package["sourceRPM"])
        require(identity and identity != "(none)", f"Missing source identity: {package['name']}")
        package["sourceIdentity"] = identity
        if identity in sources:
            continue
        key = hashlib.sha256(identity.encode()).hexdigest()[:20]
        destination = output / "sources" / key
        destination.mkdir(parents=True)
        print(f"Collecting source {identity}", flush=True)
        if manager == "apt":
            subprocess.run(["apt-get", "source", "--download-only", "--only-source", identity],
                           cwd=destination, check=True)
            descriptors = list(destination.glob("*.dsc"))
            require(len(descriptors) == 1, f"Expected one Debian source descriptor: {identity}")
            fields = deb_source_fields(descriptors[0].read_text())
            require(fields.get("Source") == package["source"] and fields.get("Version") == package["sourceVersion"],
                    f"Source package version differs from installed binary: {identity}")
            for line in fields["Checksums-Sha256"].splitlines():
                expected, size, name = line.split()
                require(pathlib.Path(name).name == name, f"Unsafe source filename: {name}")
                require((destination / name).stat().st_size == int(size), f"Source size differs: {name}")
                verify_digest(destination / name, expected)
        else:
            require(identity.endswith(".src.rpm"), f"Source RPM is incomplete: {identity}")
            spec = identity.removesuffix(".rpm")
            subprocess.run(["dnf", "download", "--srpm", "--enablerepo=fedora-source",
                            "--enablerepo=updates-source", f"--destdir={destination}", spec], check=True)
            source = destination / identity
            require(source.is_file(), f"The exact source RPM was not downloaded: {identity}")
            signature = command("env", "LC_ALL=C", "rpmkeys", "--checksig", "--verbose", str(source))
            require(re.search(r"(?mi)^.*\bSignature\b.*:\s+OK\s*$", signature),
                    f"Source RPM has no verified distribution signature: {identity}")
            require(command("rpm", "-qp", "--qf", "%{NAME}-%{VERSION}-%{RELEASE}.src.rpm", str(source)) == identity,
                    f"Source RPM version differs from installed binary: {identity}")
        sources[identity] = {"files": {f"sources/{key}/{name}": value
                                       for name, value in source_files(destination).items()},
                             "verifiedBy": "signed APT source index and .dsc SHA-256" if manager == "apt"
                             else "distribution source RPM signature"}
    editor = json.loads(pathlib.Path("/usr/lib/runfern/editor.json").read_text())
    node_version = command("/opt/openvscode-server/node", "--version")
    require(re.fullmatch(r"v\d+\.\d+\.\d+", node_version), "Unrecognized embedded Node version")
    editor_source = output / "sources/editor/source.tar.gz"
    fetch(editor["sourceURL"], editor_source, editor["sourceSHA256"])
    node_name = f"node-{node_version}.tar.xz"
    node_base = f"https://nodejs.org/dist/{node_version}/"
    checksums = urllib.request.urlopen(node_base + "SHASUMS256.txt", timeout=120).read().decode()
    matches = [fields[0] for line in checksums.splitlines()
               if len(fields := line.split()) == 2 and fields[1] == node_name]
    require(len(matches) == 1, f"No unique checksum for embedded Node source: {node_version}")
    fetch(node_base + node_name, output / "sources/node" / node_name, matches[0])
    with tarfile.open(output / "sources/node" / node_name) as archive:
        member = archive.getmember(f"node-{node_version}/LICENSE")
        require(member.isfile(), "Embedded Node source has no license document")
        node_license = output / "notices/node/LICENSE.txt"
        node_license.parent.mkdir(parents=True)
        with archive.extractfile(member) as stream, node_license.open("wb") as target:
            shutil.copyfileobj(stream, target)
    sources["OpenVSCode Server " + editor["version"]] = {
        "files": source_files(output / "sources/editor"), "url": editor["sourceURL"]}
    sources["Node.js " + node_version] = {"files": source_files(output / "sources/node"), "url": node_base + node_name}
    for identity, prefix in [("OpenVSCode Server " + editor["version"], "editor"), ("Node.js " + node_version, "node")]:
        sources[identity]["files"] = {f"sources/{prefix}/{name}": value
                                     for name, value in sources[identity]["files"].items()}
    editor_notices = []
    for path in sorted(pathlib.Path("/opt/openvscode-server").rglob("*")):
        if path.is_file() and re.match(r"(?i)^(license|copying|copyright|thirdpartynotices|notice)", path.name):
            relative = path.relative_to("/opt/openvscode-server").as_posix()
            target = output / "notices/editor" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            editor_notices.append(target.relative_to(output).as_posix())
    require(editor_notices, "Editor release contains no legal documents")
    (output / "notices/runfern").mkdir(parents=True)
    shutil.copyfile("/usr/lib/runfern/LICENSE.txt", output / "notices/runfern/LICENSE.txt")
    inventory = {"format": 1, "manager": manager, "packages": packages, "sources": sources,
                 "editor": {**editor, "nodeVersion": node_version, "notices": editor_notices},
                 "files": source_files(output)}
    write_json(output / "inventory.json", inventory)
    guest = pathlib.Path("/usr/share/runfern/licenses")
    guest.mkdir(parents=True, exist_ok=True)
    shutil.copytree(output / "notices", guest / "notices", dirs_exist_ok=True)
    shutil.copyfile(output / "inventory.json", guest / "inventory.json")
    print(f"Collected {len(packages)} installed packages and {len(sources)} exact source inputs.", flush=True)


def write_archive(path, files):
    with tarfile.open(path, "w", format=tarfile.PAX_FORMAT) as archive:
        for name, source in sorted(files.items()):
            safe_path(name)
            info = tarfile.TarInfo(name)
            info.size = source.stat().st_size
            info.mode = 0o755 if name.endswith(".sh") else 0o644
            with source.open("rb") as stream:
                archive.addfile(info, stream)


def package(build, image_id, evidence, base, editor, source_revision=None):
    inventory = json.loads((evidence / "inventory.json").read_text())
    require(inventory["format"] == 1 and inventory["packages"], "Missing guest inventory")
    for name, expected in inventory["files"].items():
        verify_digest(evidence / safe_path(name), expected)
    source_paths = {name: evidence / name for name in inventory["files"] if name.startswith("sources/")}
    own = RUNFERN_SOURCES
    source_paths.update({f"runfern/{name}": ROOT / name for name in own})
    parts, group, size = [], {}, 0
    for name, source in sorted(source_paths.items()):
        require(source.stat().st_size < SOURCE_PART_SIZE, f"Source input too large for one asset: {name}")
        if group and size + source.stat().st_size > SOURCE_PART_SIZE:
            parts.append(group)
            group, size = {}, 0
        group[name] = source
        size += source.stat().st_size
    if group:
        parts.append(group)
    assets = {}
    source_entries = {}
    for index, files in enumerate(parts, 1):
        name = f"{image_id}.sources-{index:03d}.tar"
        write_archive(build / name, files)
        assets[name] = digest(build / name)
        source_entries.update({path: {"sha256": digest(file), "asset": name} for path, file in files.items()})
    notices = {name: evidence / name for name in inventory["files"] if name.startswith("notices/")}
    notices["inventory.json"] = evidence / "inventory.json"
    name = f"{image_id}.licenses.tar"
    write_archive(build / name, notices)
    assets[name] = digest(build / name)
    image = build / f"{image_id}.runfernimage"
    build_inputs = {name: digest(ROOT / name) for name in own}
    manifest = {"format": 1, "id": image_id, "imageSHA256": digest(image),
                "bundleFiles": {path.name: digest(path) for path in sorted((build / "bundle").iterdir())},
                "cloudImage": base, "editor": editor, "buildInputs": build_inputs,
                "sourceRevision": source_revision,
                "sourceEntries": source_entries, "assets": assets,
                "inventory": inventory, "status": "COMPLETE"}
    write_json(build / f"{image_id}.evidence.json", manifest)


def verify(build, image_id, publication=False):
    require(re.fullmatch(r"[a-z0-9][a-z0-9.-]*", image_id), "Unsafe image id")
    manifest = json.loads((build / f"{image_id}.evidence.json").read_text())
    require(manifest["format"] == 1 and manifest["id"] == image_id
            and manifest["status"] == "COMPLETE", "Incomplete image evidence")
    verify_digest(build / f"{image_id}.runfernimage", manifest["imageSHA256"])
    with tarfile.open(build / f"{image_id}.runfernimage") as archive:
        members = archive.getmembers()
        require(len(members) == 4 and {member.name for member in members}
                == {"image.json", "disk.qcow2", "vmlinuz", "initrd.img"}
                and all(member.isfile() for member in members), "Invalid four-file image bundle")
        image_manifest = json.load(archive.extractfile("image.json"))
        require(image_manifest["ideVersion"] == manifest["editor"]["version"], "Image editor version differs")
        require(set(manifest["bundleFiles"]) == {member.name for member in members}, "Incomplete bundle digests")
        for member in members:
            value = hashlib.sha256()
            with archive.extractfile(member) as stream:
                for chunk in iter(lambda: stream.read(4 << 20), b""):
                    value.update(chunk)
            require(value.hexdigest() == manifest["bundleFiles"][member.name], "Bundle member differs")
    if publication:
        require(manifest.get("sourceRevision") and not manifest["sourceRevision"]["dirty"],
                "Publication requires a committed, unchanged source checkout")
        smoke = manifest.get("smokeTest", {})
        require(smoke.get("kernelVersion") == image_manifest["kernelVersion"]
                and smoke.get("editorHTTPStatus") == 200
                and set(smoke.get("toolchains", [])) >= {"python-3", "nodejs-24", "rust", "zig"},
                "Publication requires an actual agent, editor and toolchain smoke test")
    inventory = manifest["inventory"]
    require(inventory["packages"] and inventory["sources"], "Empty package/source inventory")
    for package in inventory["packages"]:
        if package.get("kind") == "distribution-signing-key":
            require(package["name"] == "gpg-pubkey", "Invalid source exception")
            continue
        require(package["sourceIdentity"] in inventory["sources"] and package["notices"],
                f"Package has no exact source or notices: {package['name']}")
        for notice in package["notices"]:
            require(notice["file"] in inventory["files"], f"Unpinned notice for {package['name']}")
    require(all(inventory["editor"].get(k) == v for k, v in manifest["editor"].items()),
            "Editor input differs from guest inventory")
    expected_sources = manifest["sourceEntries"]
    require(manifest["buildInputs"], "Missing Runfern build sources")
    for name, expected in manifest["buildInputs"].items():
        require(expected_sources.get("runfern/" + name, {}).get("sha256") == expected,
                f"Missing exact Runfern build input: {name}")
    expected_notices = {name: value for name, value in inventory["files"].items() if name.startswith("notices/")}
    seen_sources, seen_notices = set(), set()
    for name, expected in manifest["assets"].items():
        require(pathlib.Path(name).name == name and name.startswith(image_id + "."), "Unsafe asset name")
        path = build / name
        require(path.stat().st_size < MAX_ASSET, f"Release asset exceeds GitHub's limit: {name}")
        verify_digest(path, expected)
        with tarfile.open(path) as archive:
            for member in archive:
                safe_path(member.name)
                require(member.isfile(), f"Non-file evidence member: {member.name}")
                stream = archive.extractfile(member)
                value = hashlib.sha256()
                for chunk in iter(lambda: stream.read(4 << 20), b""):
                    value.update(chunk)
                if name == f"{image_id}.licenses.tar":
                    require(member.name not in seen_notices, "Duplicate legal document")
                    seen_notices.add(member.name)
                    if member.name == "inventory.json":
                        data = json.dumps(inventory, indent=2, sort_keys=True) + "\n"
                        require(value.hexdigest() == hashlib.sha256(data.encode()).hexdigest(), "Inventory differs")
                    else:
                        require(value.hexdigest() == expected_notices.get(member.name), "Legal document differs")
                else:
                    require(member.name not in seen_sources, "Duplicate source input")
                    seen_sources.add(member.name)
                    entry = expected_sources.get(member.name)
                    require(entry and entry["asset"] == name and entry["sha256"] == value.hexdigest(),
                            f"Source input differs: {member.name}")
    require(seen_sources == set(expected_sources), "Missing source inputs")
    require(seen_notices == set(expected_notices) | {"inventory.json"}, "Missing legal documents")
    for source in inventory["sources"].values():
        for name, expected in source["files"].items():
            require(expected_sources.get(name, {}).get("sha256") == expected, f"Source is not shipped: {name}")
    print(f"PASS {image_id}: {len(inventory['packages'])} packages, source inputs and legal documents verified.")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    for name in ("collect", "slim"):
        child = sub.add_parser(name)
        child.add_argument("--manager", choices=("apt", "dnf"), required=True)
        if name == "collect":
            child.add_argument("--output", type=pathlib.Path, required=True)
        else:
            child.add_argument("--kernel", required=True)
    child = sub.add_parser("verify")
    child.add_argument("id")
    child.add_argument("--build-root", type=pathlib.Path, required=True)
    child.add_argument("--publication", action="store_true")
    args = parser.parse_args()
    if args.operation == "collect":
        collect(args.manager, args.output)
    elif args.operation == "slim":
        slim(args.manager, args.kernel)
    else:
        verify(args.build_root / args.id, args.id, args.publication)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Image evidence failed: {error}")
