#!/usr/bin/env python3
"""Collect and verify licenses and corresponding sources for one Linux image."""
import argparse
import fnmatch
import hashlib
import json
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
MAX_ASSET = 2 << 30
SOURCE_PART_SIZE = 1 << 30
LICENSE_TEXT_URL = "https://raw.githubusercontent.com/spdx/license-list-data/31846481de7ea17d92f2f46fad76abe58b2e9bb0/text/"
LICENSE_TEXTS = {
    "MIT": "b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5",
    "GPL-2.0-or-later": "aaf135472f81c5b4a0dca9367e5bb5e9750032b5bebe5442b36e4c0a47430df3",
    "MPL-2.0": "66a3107d5ad6a058aab753eaac2047ccb2ed0e39465dd0fe5844da3e300d5172",
    "BSD-2-Clause": "f32fb3b417a194167cfad068223fc975ba96c5960513a10f66a3c28720aec1df",
    "BSD-3-Clause": "5a93d5831e1297ab10fe643e1a631e83be392896da14ee2951285a79012df69d",
    "CDDL-1.0": "fde9ef48461569987d09cac803379245dfda04e7751075f39b578a0ce927d470",
    "Linux-OpenIB": "6503d0418051ea29997c4c4d950386fcc356c9459a73a62d5d67707d04739b92",
    "GPL-1.0-or-later": "da37ffd5fcdf0a7d76af862a4330ea1076e1443b51782b2f912148357b7acabe",
    "GPL-2.0-only": "aaf135472f81c5b4a0dca9367e5bb5e9750032b5bebe5442b36e4c0a47430df3",
    "LGPL-2.0-or-later": "86dc99d7e5060915ab1dfc1378b7dd351c62088bfa74067e8aa1868c6fdba7d8",
    "LGPL-2.1-only": "5749785c8bdefafcb5d798270ed0a967036fe2ca63dcedade1627565dfef81d2",
    "LGPL-2.1-or-later": "5749785c8bdefafcb5d798270ed0a967036fe2ca63dcedade1627565dfef81d2",
    "Linux-syscall-note": "5bcef4fedbfc08776630e65d5d0d074dd31208037eddb167ca46a9ec4f737764",
    "Artistic-1.0-Perl": "9e18ef4d50faba562e3efa37d8961d6e9956d1c103bfc4fc1caeb07e8effe885",
    "Artistic-2.0": "bae466ac8d7100c304fe76632ccc627203a3897d3f7166f3cce00fb9df8c2074",
    "metamail": "a4b1dbdddeccbaad4687f2777ef43222eecf29ba4d9b196b1e46d11a2d57f008",
    "TermReadKey": "2739578644b799505e1f5ca5e63bfafcb0c0da9b3f5a63e9f9f0017947746d0f",
    "TTWL": "bc2c29906ea52dfa77744560479c1f0fc2218fdc6907b8d98ec08df2b77f5e53",
}
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


def download(url, target):
    require(url.startswith("https://"), f"Source download must use HTTPS: {url}")
    target = pathlib.Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["curl", "--fail", "--location", "--show-error", "--silent",
                    "--retry", "3", "--retry-all-errors", "--retry-max-time", "1200",
                    "--connect-timeout", "30", "--max-time", "900",
                    "--proto", "=https", "--proto-redir", "=https",
                    "--output", str(target), url], check=True)


def fetch(url, target, expected):
    require(url.startswith("https://"), f"Source download must use HTTPS: {url}")
    target = pathlib.Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        temporary = target.with_name(target.name + ".download")
        try:
            download(url, temporary)
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
        removal = (["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "purge", "-y"]
                   if manager == "apt" else ["dnf", "remove", "-y"])
        if manager == "dnf" and f"kernel-core-{command('uname', '-r')}" in remove:
            # Permit only this disposable VM's superseded kernel; retain the final boot target.
            removal.append("--setopt=protect_running_kernel=False")
        subprocess.run(removal + remove, check=True)
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


def rpm_source(package, destination):
    identity = package["sourceRPM"]
    require(identity.endswith(".src.rpm") and pathlib.Path(identity).name == identity,
            f"Source RPM is incomplete: {identity}")
    source = destination / identity
    temporary = source.with_name(source.name + ".download")
    try:
        checked = source
        if not source.exists():
            signature = command("env", "LC_ALL=C", "rpm", "-q", "--qf", "%{RSAHEADER:pgpsig}", package["name"])
            match = re.search(r"(?i)\bKey ID ([0-9a-f]{8,16})\b", signature)
            require(match, f"Installed RPM has no distribution signing key: {package['name']}")
            parts = identity.removesuffix(".src.rpm").rsplit("-", 2)
            require(len(parts) == 3, f"Invalid source RPM version: {identity}")
            path = "/".join(urllib.parse.quote(part, safe="") for part in
                            (*parts, "data", "signed", match[1].lower()[-8:], "src", identity))
            url = "https://kojipkgs.fedoraproject.org/packages/" + path
            print(f"Downloading archived distribution-signed source: {identity}", flush=True)
            download(url, temporary)
            checked = temporary
        signature = command("env", "LC_ALL=C", "rpmkeys", "--checksig", "--verbose", str(checked))
        require(re.search(r"(?mi)^.*\bSignature\b.*:\s+OK\s*$", signature),
                f"Source RPM has no verified distribution signature: {identity}")
        require(command("rpm", "-qp", "--qf", "%{NAME}-%{VERSION}-%{RELEASE}.src.rpm", str(checked)) == identity,
                f"Source RPM version differs from installed binary: {identity}")
        if checked == temporary:
            temporary.replace(source)
    finally:
        temporary.unlink(missing_ok=True)
    return source


def license_texts(names, output):
    require(names, "Missing standard license declaration")
    unknown = set(names) - set(LICENSE_TEXTS)
    require(not unknown, f"Unreviewed standard license or exception: {', '.join(sorted(unknown))}")
    result = []
    for name in sorted(names):
        target = output / "sources/license-texts" / (name + ".txt")
        fetch(LICENSE_TEXT_URL + name + ".txt", target, LICENSE_TEXTS[name])
        result.append(target)
    return result


def ca_certificate_notices(package, output):
    identity = package["sourceRPM"]
    require(package["name"] == "ca-certificates" and identity.startswith("ca-certificates-")
            and package["license"] == "MIT AND GPL-2.0-or-later",
            "Unreviewed certificate package license or source identity")
    destination = output / "sources" / hashlib.sha256(identity.encode()).hexdigest()[:20]
    destination.mkdir(parents=True, exist_ok=True)
    source = rpm_source(package, destination)
    notices = []
    for name in ("ca-certificates.spec", "certdata.txt", "certdata2pem.py", "nssckbi.h"):
        data = subprocess.check_output(["bsdtar", "-xOf", str(source), name])
        require(data.strip() and b"\0" not in data, f"Unreadable certificate source notice: {name}")
        if name == "certdata.txt":
            require(b"Mozilla Public" in data and b"License, v. 2.0" in data,
                    "Certificate source license changed; review its notices")
        target = output / "certificate-source-notices" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        notices.append(target)
    notices.extend(license_texts(("MIT", "GPL-2.0-or-later", "MPL-2.0"), output))
    return notices


def original_source_files(path):
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():
                if not member.is_dir():
                    with archive.open(member) as stream:
                        yield member.filename, stream
    else:
        with tarfile.open(path, mode="r|*") as archive:
            for member in archive:
                if member.isfile():
                    with archive.extractfile(member) as stream:
                        yield member.name, stream


def source_rpm_notices(package, output):
    identity = package["sourceRPM"]
    key = hashlib.sha256(identity.encode()).hexdigest()[:20]
    destination = output / "sources" / key
    destination.mkdir(parents=True, exist_ok=True)
    source = rpm_source(package, destination)
    notices = []
    if identity.removesuffix(".src.rpm").rsplit("-", 2)[0] == "shim":
        macros = subprocess.check_output(["bsdtar", "-xOf", str(source), "shim.rpmmacros"])
        version = re.findall(rb"(?m)^%global shimveraa64\s+(\S+)\s*$", macros)
        name = re.findall(rb"(?m)^%global unsignedaa64\s+(\S+)\s*$", macros)
        require(len(version) == len(name) == 1 and name[0] == b"shim-unsigned-aarch64",
                "Unreviewed signed shim source mapping")
        corresponding = (name[0] + b"-" + version[0] + b".src.rpm").decode()
        source = rpm_source({**package, "sourceRPM": corresponding}, destination)
        package["correspondingSourceRPM"] = corresponding
    headers = identity.startswith("kernel-headers-")
    perl = identity.startswith("perl-")
    header_count = 0
    if headers or perl:
        spec_name = identity.removesuffix(".src.rpm").rsplit("-", 2)[0] + ".spec"
        specification = subprocess.check_output(["bsdtar", "-xOf", str(source), spec_name])
        declared = re.findall(rb"(?m)^License:\s+(.+)$", specification)
        require(any(b" ".join(value.split()) == b" ".join(package["license"].encode().split()) for value in declared),
                "Package source license differs from installed metadata")
        identifiers = set(re.findall(r"[A-Za-z0-9.+-]+", package["license"])) - {"AND", "OR", "WITH"}
        notices.extend(license_texts(identifiers, output))
        target = output / "source-notices" / key / spec_name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(specification)
        notices.append(target)
    original_start = len(notices)

    def collect_legal(archive, prefix):
        for member in command("bsdtar", "-tf", str(archive)).splitlines():
            if not member.endswith("/") and re.fullmatch(
                    r"(?i)(copying|copyright|licen[cs]e|notice)([.-].*)?", pathlib.PurePosixPath(member).name):
                data = subprocess.check_output(["bsdtar", "-xOf", str(archive), member])
                require(data.strip() and b"\0" not in data, f"Unreadable source legal document: {member}")
                name = hashlib.sha256((prefix + member).encode()).hexdigest()[:20]
                target = output / "source-notices" / key / (name + ".txt")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                notices.append(target)

    collect_legal(source, "")
    with tempfile.TemporaryDirectory(dir=output) as temporary:
        for index, member in enumerate(command("bsdtar", "-tf", str(source)).splitlines()):
            if member.endswith((".tar", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".tar.zst", ".zip", ".crate")):
                nested = pathlib.Path(temporary) / str(index)
                with nested.open("wb") as stream:
                    subprocess.run(["bsdtar", "-xOf", str(source), member], stdout=stream, check=True)
                collect_legal(nested, member + ":")
                if headers or perl:
                    target = output / "source-notices" / key / f"original-{'headers' if headers else 'perl'}-{index}.txt"
                    copied = 0
                    with target.open("wb") as stream:
                        for name, original in original_source_files(nested):
                            eligible = not headers or name.endswith(".h")
                            if eligible:
                                data = original.read()
                                if perl and (b"\0" in data or not re.search(rb"(?i)\b(copyright|licen[cs]e)\b", data)):
                                    continue
                                require(data.strip() and b"\0" not in data,
                                        f"Unreadable original source notice: {name}")
                                stream.write(f"\nOriginal source member: {member}:{name}\n".encode())
                                stream.write(data)
                                header_count += int(headers)
                                copied += 1
                    if copied:
                        notices.append(target)
                    else:
                        target.unlink()
    require(not headers or header_count > 0, "Kernel source archive contains no original header notices")
    require(not perl or len(notices) > original_start, "Perl source contains no original copyright/license notices")
    public_domain = package.get("license") == "LicenseRef-Fedora-Public-Domain"
    noncopyrightable = package.get("license") == "LicenseRef-Not-Copyrightable"
    if not notices and (identity.startswith("fedora-repos-") or public_domain or noncopyrightable):
        require(public_domain or noncopyrightable or package["license"] == "MIT",
                "Unreviewed Fedora repository metadata license")
        name = identity.removesuffix(".src.rpm").rsplit("-", 2)[0] + ".spec"
        specification = subprocess.check_output(["bsdtar", "-xOf", str(source), name])
        require(re.search(rb"(?m)^License:\s+" + re.escape(package["license"].encode()) + rb"\s*$", specification),
                "Distribution source license differs from installed metadata")
        target = output / "source-notices" / key / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(specification)
        notices.append(target)
        if not public_domain and not noncopyrightable:
            notices.extend(license_texts(("MIT",), output))
        if noncopyrightable:
            for member in re.findall(rb"(?m)^Source[0-9]*:\s+(\S+)\s*$", specification):
                member = member.decode()
                safe_path(member)
                data = subprocess.check_output(["bsdtar", "-xOf", str(source), member])
                require(data.strip() and b"\0" not in data, f"Unreadable original configuration: {member}")
                target = output / "source-notices" / key / member
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                notices.append(target)
    return notices


def copy_notices(package, manager, output, providers):
    if manager == "apt":
        paths = command("dpkg-query", "-L", package["name"]).splitlines()
        selected = [pathlib.Path(p) for p in paths if p.endswith("/copyright")]
        selected.append(pathlib.Path("/usr/share/doc", package["name"].split(":")[0], "copyright"))
    else:
        paths = command("rpm", "-q", "--licensefiles", package["name"]).splitlines()
        selected = [pathlib.Path(p) for p in paths]
        if package["sourceRPM"].removesuffix(".src.rpm").rsplit("-", 2)[0] == "shim":
            selected.extend(source_rpm_notices(package, output))
        if not any(path.is_file() for path in selected):
            selected = providers.get(package["sourceRPM"], [])
        if not any(path.is_file() for path in selected) and package["name"] == "ca-certificates":
            selected = ca_certificate_notices(package, output)
        if not any(path.is_file() for path in selected):
            entries = command("rpm", "-q", "--qf", "[%{FILENAMES}\t%{FILEMODES:octal}\n]",
                              package["name"]).splitlines()
            if all(stat.S_ISDIR(int(entry.split("\t")[1], 8)) for entry in entries):
                package["kind"] = "directory-metadata"
                target = output / "rpm-metadata" / (package["name"] + ".txt")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(f"{package['name']} {package['version']}\n"
                                  f"RPM license declaration: {package['license']}\n"
                                  "This package installs only directories or no files; no program or data files.\n"
                                  f"Exact accompanying source RPM: {package['sourceRPM']}\n")
                selected = [target]
                print(f"Recorded directory-only RPM metadata: {package['name']}", flush=True)
            else:
                selected = source_rpm_notices(package, output)
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
        if path.parent == output / "sources/license-texts":
            require(path.stem in LICENSE_TEXTS, "Unreviewed standard license notice")
            verify_digest(path, LICENSE_TEXTS[path.stem])
            origin = {"sourceURL": LICENSE_TEXT_URL + path.name, "sha256": LICENSE_TEXTS[path.stem]}
        else:
            origin = ({"sourceRPM": package.get("correspondingSourceRPM", package["sourceRPM"]),
                       "sourceNotice": path.relative_to(output).as_posix()}
                      if path.is_relative_to(output) else {"installedPath": str(path)})
        result.append({"file": target.relative_to(output).as_posix(), **origin})
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
        destination.mkdir(parents=True, exist_ok=True)
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
            rpm_source(package, destination)
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
    checksum_file = output / "sources/node/SHASUMS256.txt"
    download(node_base + checksum_file.name, checksum_file)
    checksums = checksum_file.read_text()
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
    if (output / "sources/license-texts").is_dir():
        sources["SPDX license texts"] = {"files": {f"sources/license-texts/{name}": value for name, value
                                                  in source_files(output / "sources/license-texts").items()},
                                        "url": LICENSE_TEXT_URL}
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
        if package.get("correspondingSourceRPM"):
            files = inventory["sources"][package["sourceIdentity"]]["files"]
            matches = [path for path in files if path.endswith("/" + package["correspondingSourceRPM"])]
            require(len(matches) == 1 and manifest["sourceEntries"].get(matches[0], {}).get("sha256") == files[matches[0]],
                    f"Missing actual compiled source behind signed binary: {package['name']}")
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
