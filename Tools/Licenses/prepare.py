#!/usr/bin/env python3
"""Collect exact public notices and a deterministic source-input archive. No release clearance."""
import argparse
import concurrent.futures
import gzip
import hashlib
import io
import json
import re
import subprocess
import tarfile
import tomllib
import urllib.request
import zipfile
from pathlib import Path
from macho import fingerprint
from version import SOURCE_ARCHIVE, VERSION

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/licenses"
RES = ROOT / "Runfern/Resources/Licenses"
STIK = "b3e01a30ded4cd0b27cf1b6bd42f123bbdf49c3a"
IDEVICE = "d32c8189c51c2789496b0768039419c3705498c3"
DEVICON = "32fe1d3b3f36ad11f90ab94f7db59738139c2bf6"
UTM_COMMIT = "1c5e2150696cf86dc6e451212a8ad4555b2b63b2"
PACKAGES = [
    ("QEMU", "qemu-10.0.12-utm", "GPL-2.0; per-file compatible licenses",
     "Linux VM (interpreter and JIT)", "QEMU_SRC"),
    ("GLib / GIO / GObject / GModule", "glib-2.83.0", "LGPL-2.1-or-later; per-file licenses",
     "QEMU runtime libraries", "GLIB_SRC"),
    ("GNU libiconv", "libiconv-1.16", "LGPL-2.1-or-later (library); GPL (tools)",
     "Character conversion", "ICONV_SRC"),
    ("GNU gettext / libintl", "gettext-0.22.5", "LGPL-2.1-or-later (libintl); GPL (tools)",
     "QEMU internationalization", "GETTEXT_SRC"),
    ("libffi", "libffi-3.5.0", "MIT; per-file licenses", "Foreign function interface", "FFI_SRC"),
    ("pixman", "pixman-0.38.0", "MIT; per-file licenses", "QEMU pixel operations", "PIXMAN_SRC"),
    ("libslirp", "libslirp-v4.9.1", "BSD and other per-file licenses", "QEMU networking", "SLIRP_SRC"),
    ("Zstandard", "zstd-1.5.2", "BSD-3-Clause OR GPL-2.0", "QEMU compression", "ZSTD_SRC"),
    ("pkg-config (build tool)", "pkg-config-0.29.2", "GPL-2.0-or-later",
     "Corresponding-source build tool, not embedded", "PKG_CONFIG_SRC"),
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def fetch(url, target, expected=None):
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(url, headers={"User-Agent": "Runfern-license-audit"})
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
        if expected and digest(data) != expected:
            raise ValueError(f"Checksum mismatch: {url}")
        target.write_bytes(data)
    if expected and digest(target.read_bytes()) != expected:
        raise ValueError(f"Checksum mismatch: {target}")
    return target


def legal_records(files):
    """Preserve whole legal documents and exact initial source notice comments."""
    records = {}
    for name, data in sorted(files.items()):
        if len(data) > 2_000_000 or b"\0" in data:
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            text = data.decode("latin-1")
        basename = Path(name).name.lower()
        if (re.match(r"^(copying|copyright|licen[cs]e|notice|authors|thirdparty)", basename)
                or "/LICENSES/" in name):
            if text.strip():
                records[name] = text
        elif Path(name).suffix in (".c", ".h", ".rs", ".S", ".cpp", ".swift", ".js", ".py"):
            # Leading comment blocks can be separated by whitespace or other comment blocks.
            comment = r"#[^\n]*\n" if Path(name).suffix == ".py" else r"/\*.*?\*/|//[^\n]*\n"
            match = re.match(r"\s*((?:(?:" + comment + r")\s*)+)", text, re.S)
            if match and re.search(r"copyright|permission|SPDX-License|licensed under",
                                   match[1], re.I):
                records[name] = match[1]
    return records


def tar_files(path, exclude=()):
    result = {}
    with tarfile.open(path, mode="r|*") as archive:
        for member in archive:
            name = "/".join(member.name.split("/")[1:])
            if member.isfile() and name and name.split("/")[0] not in exclude:
                result[name] = archive.extractfile(member).read()
    return result


def write_tar(path, entries):
    # Reproducible independent of local mtime, uid, absolute paths and gzip timestamp.
    with path.open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for name, data in sorted(entries.items()):
                    member = tarfile.TarInfo(name)
                    member.size = len(data)
                    member.mode = 0o755 if name.endswith(".sh") else 0o644
                    archive.addfile(member, io.BytesIO(data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--utm", type=Path, default=Path.home() / "RunfernBuild/UTM")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    RES.mkdir(parents=True, exist_ok=True)
    source_entries, notices, blockers = {}, [], []
    provenance = {"utmCommit": UTM_COMMIT, "sources": [], "binaries": [], "logos": []}

    def add(name, version, license_name, role, files, url, jit=False):
        if name == "QEMU":
            files = {p: data for p, data in files.items()
                     if p.split("/")[0] not in ("roms", "pc-bios", "tests")}
        records = legal_records(files)
        if not records:
            blockers.append(f"{name}: no exact legal text in supplied source")
            return
        filename = f"notice-{len(notices):03d}.txt"
        body = f"{name} — {version}\nSource: {url}\n\n"
        identical = {}
        for path, text in records.items():
            identical.setdefault(text, []).append(path)
        body += "\n\n".join(f"===== {', '.join(paths)} =====\n{text}"
                             for text, paths in identical.items())
        (RES / filename).write_text(body, encoding="utf-8")
        notices.append({"id": filename, "name": name, "version": version,
                        "license": license_name, "role": role, "file": filename,
                        "jitOnly": jit, "sha256": digest(body.encode())})

    if run("git", "-C", str(args.utm), "rev-parse", "HEAD") != UTM_COMMIT:
        raise ValueError("UTM checkout does not match audited commit")
    public_utm = subprocess.check_output(["git", "-C", str(args.utm), "archive", UTM_COMMIT,
                                        "scripts/build_dependencies.sh", "scripts/fixup.sh",
                                        "scripts/resources", "patches", "LICENSE"])
    source_entries["sources/utm.tar"] = public_utm
    source_entries["build/build_runfern_qemu.sh"] = (args.utm / "scripts/build_runfern_qemu.sh").read_bytes()
    for path in (ROOT / "Tools/QEMU").iterdir():
        if path.suffix in (".sh", ".py", ".md"):
            source_entries[f"build/Tools/QEMU/{path.name}"] = path.read_bytes()
    for path in (ROOT / "Tools/JIT").glob("build*.sh"):
        source_entries[f"build/Tools/JIT/{path.name}"] = path.read_bytes()
    for path in Path(__file__).parent.iterdir():
        if path.is_file() and path.suffix in (".py", ".md"):
            source_entries[f"build/Tools/Licenses/{path.name}"] = path.read_bytes()

    urls = dict(re.findall(r'^(\w+)="([^"]+)"', (args.utm / "patches/sources").read_text(), re.M))
    for name, directory, license_name, role, url_key in PACKAGES:
        base_files, base_checksum = None, None
        for platform in ("build-iOS-TCI-arm64", "build-iOS-arm64", "build-iOS_Simulator-TCI-arm64"):
            build = args.utm / platform
            candidates = list(build.glob(directory + ".tar.*"))
            if len(candidates) != 1:
                raise ValueError(f"Missing/unambiguous original source archive: {platform}/{directory}")
            original = candidates[0]
            data = original.read_bytes()
            source_entries[f"sources/{platform}/{original.name}"] = data
            checksum = digest(data)
            if base_checksum == checksum:
                files = dict(base_files)
            else:
                files = tar_files(original, ("roms", "pc-bios", "tests") if name == "QEMU" else ())
                if base_files is None:
                    base_files, base_checksum = dict(files), checksum
            # Capture the exact file-level changes in the actual build source tree, not a
            # claim that upstream patches alone represent the locally compiled sources.
            changed = {}
            for relative, before in files.items():
                local = build / directory / relative
                if local.is_file() and not local.is_symlink():
                    after = local.read_bytes()
                    if before != after:
                        changed[relative] = after
                        files[relative] = after
                elif not local.exists():
                    blockers.append(f"{platform}/{directory}/{relative}: original source missing locally")
            patch_data = args.utm / "patches/data" / directory
            if patch_data.exists():
                for local in patch_data.rglob("*"):
                    if local.is_file():
                        relative = local.relative_to(patch_data).as_posix()
                        built = build / directory / relative
                        if not built.is_file():
                            raise ValueError(f"Missing applied patch data: {built}")
                        changed[relative] = files[relative] = built.read_bytes()
            for relative, value in changed.items():
                source_entries[f"overrides/{platform}/{directory}/{relative}"] = value
            provenance["sources"].append({"name": directory, "platform": platform,
                                          "url": urls[url_key], "sha256": digest(data),
                                          "overrides": len(changed)})
            if platform == "build-iOS-TCI-arm64":
                add(name, directory, license_name, role, files, urls[url_key])
            # Include configure/meson evidence, but not logs or unrelated developer data.
            for directory_name in ("build", "utm_build"):
                config = build / directory / directory_name
                for filename in ("config-host.mak", "config-host.h", "config.status",
                                 "meson-info/intro-buildoptions.json", "meson-private/cmd_line.txt"):
                    path = config / filename
                    if path.is_file():
                        source_entries[f"configuration/{platform}/{directory}/{filename}"] = path.read_bytes()
        print("Collected", directory, flush=True)

    for platform in ("build-iOS-TCI-arm64", "build-iOS-arm64", "build-iOS_Simulator-TCI-arm64"):
        path = args.utm / platform / "libucontext.git"
        commit = run("git", "-C", str(path), "rev-parse", "HEAD")
        if commit != urls["LIBUCONTEXT_COMMIT"] or run("git", "-C", str(path), "status", "--porcelain"):
            raise ValueError(f"Unexpected libucontext source: {platform}")
        data = subprocess.check_output(["git", "-C", str(path), "archive", commit])
        source_entries[f"sources/{platform}/libucontext.tar"] = data
        if platform == "build-iOS-TCI-arm64":
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                files = {m.name: archive.extractfile(m).read() for m in archive if m.isfile()}
            add("libucontext", commit, "ISC", "Statically linked QEMU coroutine implementation",
                files, urls["LIBUCONTEXT_REPO"] + "/tree/" + commit)

    for platform in ("build-iOS-TCI-arm64", "build-iOS-arm64", "build-iOS_Simulator-TCI-arm64"):
        build = args.utm / platform
        subprojects = build / "glib-2.83.0/subprojects"
        wrap = dict(re.findall(r"^(\w+) = (.+)$", (subprojects / "pcre2.wrap").read_text(), re.M))
        original = subprojects / "packagecache" / wrap["source_filename"]
        patch = subprojects / "packagecache" / wrap["patch_filename"]
        for path, checksum in ((original, wrap["source_hash"]), (patch, wrap["patch_hash"])):
            if not path.is_file() or digest(path.read_bytes()) != checksum:
                raise ValueError(f"Missing or mismatched PCRE2 source/patch: {platform}/{path.name}")
            source_entries[f"sources/{platform}/pcre2/{path.name}"] = path.read_bytes()
        files = tar_files(original)
        with zipfile.ZipFile(patch) as archive:
            for name in archive.namelist():
                relative = "/".join(name.split("/")[1:])
                if relative and not name.endswith("/"):
                    files[relative] = archive.read(name)
        for relative, before in list(files.items()):
            local = subprojects / wrap["directory"] / relative
            if local.is_file() and local.read_bytes() != before:
                files[relative] = local.read_bytes()
                source_entries[f"overrides/{platform}/pcre2-10.44/{relative}"] = files[relative]
        provenance["sources"].append({"name": "pcre2-10.44", "platform": platform,
                                      "url": wrap["source_url"], "sha256": wrap["source_hash"],
                                      "patchURL": wrap["patch_url"], "patchSHA256": wrap["patch_hash"]})
        if platform == "build-iOS-TCI-arm64":
            add("PCRE2", "10.44", "BSD-3-Clause; per-file notices",
                "Statically embedded regular expressions used by QEMU/GLib",
                files, wrap["source_url"])

        dtc = build / "qemu-10.0.12-utm/subprojects/dtc"
        wrap = dict(re.findall(r"^(\w+) = (.+)$", (dtc.parent / "dtc.wrap").read_text(), re.M))
        commit = run("git", "-C", str(dtc), "rev-parse", "HEAD")
        status = run("git", "-C", str(dtc), "status", "--porcelain")
        unexpected = [line for line in status.splitlines()
                      if line != "?? .meson-subproject-wrap-hash.txt"]
        if commit != wrap["revision"] or unexpected:
            raise ValueError(f"Unexpected libfdt/dtc source: {platform}")
        data = subprocess.check_output(["git", "-C", str(dtc), "archive", commit])
        source_entries[f"sources/{platform}/dtc-libfdt.tar"] = data
        provenance["sources"].append({"name": "dtc/libfdt", "platform": platform,
                                      "url": wrap["url"], "commit": commit, "sha256": digest(data)})
        if platform == "build-iOS-TCI-arm64":
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                files = {m.name: archive.extractfile(m).read() for m in archive if m.isfile()}
            files["LICENSE-BSD-2-Clause"] = files["BSD-2-Clause"]
            files["LICENSE-GPL"] = files["GPL"]
            add("libfdt / Device Tree Compiler", commit, "BSD-2-Clause OR GPL-2.0 (libfdt); GPL (tools)",
                "Statically embedded QEMU device-tree library", files,
                wrap["url"] + "/-/tree/" + commit)

    # Build products are hashed but are never put in the source bundle.
    for sdk, platform in (("iphoneos", "sysroot-iOS-TCI-arm64"),
                          ("iphonesimulator", "sysroot-iOS_Simulator-TCI-arm64")):
        for framework in sorted((ROOT / "Vendor/QEMU" / sdk).glob("*.framework")):
            name = framework.stem
            binary = framework / name
            build_platform = "sysroot-iOS-arm64" if name.endswith("-jit") else platform
            original_name = name.removesuffix("-jit")
            original = args.utm / build_platform / "Frameworks" / f"{original_name}.framework" / original_name
            uuid = run("dwarfdump", "--uuid", str(binary)).split()[1]
            if uuid != run("dwarfdump", "--uuid", str(original)).split()[1]:
                blockers.append(f"{sdk}/{name}: build/vendor Mach-O UUID mismatch")
            provenance["binaries"].append({"path": binary.relative_to(ROOT).as_posix(),
                                          "sha256": digest(binary.read_bytes()), "uuid": uuid,
                                          "codeFingerprint": fingerprint(binary.read_bytes()),
                                          "links": run("otool", "-L", str(binary)).splitlines()[1:]})
    blockers.append("QEMU build trees have no compile-time source hash/build attestation. "
                    "Matching vendor/sysroot Mach-O UUIDs establish copied build products, "
                    "not proof that current source trees exactly correspond to those binaries. "
                    "Rebuild from the recorded source inputs with source/build attestation before release.")

    for name, commit, repository, license_name, role in (
            ("StikJIT", STIK, "StikDebug/StikJIT", "MPL-2.0", "JIT debugger (sideload only)"),
            ("idevice", IDEVICE, "jkcoxson/idevice", "MIT; dependency licenses below",
             "JIT pairing / device services (sideload only)")):
        url = f"https://codeload.github.com/{repository}/tar.gz/{commit}"
        archive = fetch(url, OUT / "upstream" / f"{name.lower()}.tar.gz")
        source_entries[f"sources/{name}.tar.gz"] = archive.read_bytes()
        files = tar_files(archive)
        # StikJIT's public repository includes prebuilt static libraries. Do not
        # redistribute them as purported source, or put binaries into this bundle.
        if name == "StikJIT":
            cleaned = {f"StikJIT/{p}": b for p, b in files.items()
                       if Path(p).suffix not in (".a", ".dylib", ".so")}
            clean_path = OUT / "StikJIT-source.tar.gz"
            write_tar(clean_path, cleaned)
            source_entries[f"sources/{name}.tar.gz"] = clean_path.read_bytes()
            clean_path.unlink()
            blockers.append("StikJIT 2.0.1 embeds idevice/libidevice_ffi.a and tvOS variant; "
                            "upstream does not pin their source commit, Cargo.lock, or features. "
                            "idevice v0.1.68 notices are NOT proof of these embedded libraries' provenance.")
        add(name, commit, license_name, role, files,
            f"https://github.com/{repository}/tree/{commit}", True)
        provenance["sources"].append({"name": name, "url": url,
                                      "sha256": digest(archive.read_bytes())})
        if name == "idevice":
            lock = tomllib.loads(files["Cargo.lock"].decode())
            registry = [p for p in lock["package"] if p.get("source", "").startswith("registry+")]

    for name, url, expected, prefix, selected in (
            ("StikJIT", "https://github.com/StikDebug/StikJIT/releases/download/2.0.1/StikJIT.xcframework.zip",
             "c376687326a785f5ed1da8caca08adc709b56919019dd751bca059b92b175d95",
             "StikJIT.xcframework/",
             ["ios-arm64/StikJIT.framework/StikJIT", "ios-arm64/StikJIT.framework/legacy.js",
              "ios-arm64/StikJIT.framework/universal.js", "tvos-arm64/StikJIT.framework/StikJIT",
              "tvos-arm64/StikJIT.framework/legacy.js", "tvos-arm64/StikJIT.framework/universal.js"]),
            ("IDevice", "https://github.com/jkcoxson/idevice/releases/download/v0.1.68/idevice-xcframework-v0.1.68.zip",
             "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7",
             "swift/IDevice.xcframework/", ["ios-arm64/libidevice_ffi.a"])):
        print("Verifying pinned release binary:", name, flush=True)
        path = fetch(url, OUT / "upstream" / f"{name}-release.zip", expected)
        with zipfile.ZipFile(path) as archive:
            for relative in selected:
                local = ROOT / "Vendor/JIT" / (name + ".xcframework") / relative
                released = archive.read(prefix + relative)
                if not local.is_file() or local.read_bytes() != released:
                    blockers.append(f"{name}/{relative}: does not match checksum-pinned release binary")
                if local.is_file():
                    record = {"path": local.relative_to(ROOT).as_posix(),
                              "sha256": digest(local.read_bytes()), "releaseSHA256": expected}
                    if relative.endswith(".framework/StikJIT"):
                        record["uuid"] = run("dwarfdump", "--uuid", str(local)).split()[1]
                        record["codeFingerprint"] = fingerprint(local.read_bytes())
                    provenance["binaries"].append(record)

    def crate(package):
        name, version = package["name"], package["version"]
        url = f"https://static.crates.io/crates/{name}/{name}-{version}.crate"
        archive = fetch(url, OUT / "upstream/crates" / f"{name}-{version}.crate", package["checksum"])
        files = tar_files(archive)
        manifest = tomllib.loads(files["Cargo.toml"].decode())["package"]
        return package, archive, files, manifest, url

    print(f"Collecting {len(registry)} checksum-pinned Rust crates (conservative lockfile superset)", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        crates = list(pool.map(crate, registry))
    for package, archive, files, manifest, url in sorted(crates, key=lambda c: (c[0]["name"], c[0]["version"])):
        source_entries[f"sources/crates/{archive.name}"] = archive.read_bytes()
        if not legal_records(files):
            vcs = json.loads(files.get(".cargo_vcs_info.json", b"{}"))
            revision = vcs.get("git", {}).get("sha1")
            repository = re.match(r"https://github.com/([^/]+/[^/]+)",
                                  manifest.get("repository", "").rstrip("/"))
            if revision and repository and not vcs.get("git", {}).get("dirty"):
                repository = repository[1].removesuffix(".git")
                directory = Path(vcs.get("path_in_vcs", ""))
                parents = [directory.as_posix()] + [p.as_posix() for p in directory.parents]
                for directory_name in dict.fromkeys(parents + ["."]):
                    directory_name = "" if directory_name == "." else directory_name
                    api = f"https://api.github.com/repos/{repository}/contents/{directory_name}?ref={revision}"
                    cache = OUT / "upstream/crate-vcs" / f"{package['name']}-{package['version']}" / directory_name
                    try:
                        listing = json.loads(fetch(api, cache / "contents.json").read_bytes())
                    except urllib.error.HTTPError as error:
                        if error.code == 404:
                            continue
                        raise
                    for entry in listing:
                        if entry["type"] != "file" or not re.match(
                                r"^(copying|copyright|licen[cs]e|notice|authors)", entry["name"], re.I):
                            continue
                        license_url = f"https://raw.githubusercontent.com/{repository}/{revision}/{entry['path']}"
                        legal = fetch(license_url, cache / entry["name"]).read_bytes()
                        relative = f"UPSTREAM/{revision}/{entry['path']}"
                        files[relative] = legal
                        source_entries[f"sources/crate-notices/{package['name']}-{package['version']}/{entry['path']}"] = legal
                        provenance["sources"].append({"name": package["name"], "version": package["version"],
                                                      "kind": "crate-notice-supplement", "url": license_url,
                                                      "gitRevision": revision, "sha256": digest(legal)})
        add("Rust crate: " + package["name"], package["version"],
            manifest.get("license", manifest.get("license-file", "UNRESOLVED")),
            "idevice lockfile superset; includes optional/build/other-platform dependencies",
            files, url, True)
    blockers.append("idevice release static-library feature/link map not supplied: all 359 locked "
                    "registry packages retained conservatively; binary correspondence not demonstrated.")

    license_url = f"https://raw.githubusercontent.com/devicons/devicon/{DEVICON}/LICENSE"
    devicon_license = fetch(license_url, OUT / "upstream/devicon-LICENSE").read_bytes()
    add("Devicon language logos", DEVICON, "MIT; project trademarks retained",
        "Language picker artwork; no endorsement or trademark grant",
        {"LICENSE": devicon_license}, license_url)
    for imageset in sorted((ROOT / "Runfern/Resources/Assets.xcassets").glob("lang-*.imageset")):
        logo = next(imageset.glob("*.svg"))
        family = imageset.stem.removeprefix("lang-")
        upstream_family = {"deno": "denojs", "dotnet": "dot-net"}.get(family, family)
        matched = None
        for style in ("original", "plain", "original-wordmark", "plain-wordmark"):
            url = f"https://raw.githubusercontent.com/devicons/devicon/{DEVICON}/icons/{upstream_family}/{upstream_family}-{style}.svg"
            try:
                remote = fetch(url, OUT / "upstream/logos" / f"{family}-{style}.svg").read_bytes()
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    continue
                raise
            if remote.strip() == logo.read_bytes().strip():
                matched = url
                break
        provenance["logos"].append({"path": logo.relative_to(ROOT).as_posix(),
                                    "sha256": digest(logo.read_bytes()), "url": matched})
        if not matched:
            blockers.append(f"Devicon {family}: local SVG does not match audited public revision")

    # The guest is distributed separately, but its actual editor and package notices
    # belong in the inventory; absent image package manifests must stop publication.
    guest_versions = {}
    for image in sorted((ROOT / "Tools/GuestImage/build").glob("*/bundle/image.json")):
        metadata = json.loads(image.read_text())
        guest_versions[image.parent.parent.name] = metadata.get("ideVersion")
    provenance["guestEditors"] = guest_versions
    for version in sorted(set(v for v in guest_versions.values() if v)):
        tag_url = f"https://api.github.com/repos/gitpod-io/openvscode-server/git/ref/tags/{version}"
        ref = json.loads(fetch(tag_url, OUT / "upstream" / f"{version}-ref.json").read_bytes())
        commit = ref["object"]["sha"]
        if ref["object"]["type"] != "commit":
            raise ValueError("Editor tag requires explicit annotated-tag resolution")
        files = {}
        for filename in ("LICENSE.txt", "ThirdPartyNotices.txt"):
            url = f"https://raw.githubusercontent.com/gitpod-io/openvscode-server/{commit}/{filename}"
            files[filename] = fetch(url, OUT / "upstream" / f"{version}-{filename}").read_bytes()
        add("OpenVSCode Server / Code OSS", version, "MIT; third-party notices",
            "Editor inside separately downloaded Linux guest", files,
            f"https://github.com/gitpod-io/openvscode-server/tree/{commit}")
    blockers.append("Guest images: no installed dpkg/rpm inventory with exact versions, "
                    "copyright/license texts, or corresponding source packages for kernels and GPL software; "
                    "latest cloud/editor URLs in build_image.py are not reproducible release pins.")
    catalog = json.loads((ROOT / "Catalog/catalog.json").read_text())
    for toolchain in catalog["toolchains"]:
        package_records = {}
        for package in toolchain.get("packages", []):
            expected = package["sha256"]
            cached = []
            for directory in (ROOT / "Tools/GuestImage/build/packages", Path.home() / "RunfernBuild/pkgs"):
                cached.extend(directory.glob(expected + ".*"))
            if not cached:
                continue
            archive = cached[0]
            require_hash = digest(archive.read_bytes())
            if require_hash != expected:
                raise ValueError(f"Guest package checksum mismatch: {toolchain['id']}")
            with tarfile.open(archive) as contents:
                for member in contents:
                    if not member.isfile() or member.size > 2_000_000:
                        continue
                    basename = Path(member.name).name.lower()
                    if re.match(r"^(copying|copyright|licen[cs]e|notice|authors|thirdparty)", basename):
                        package_records[expected + "/" + member.name] = contents.extractfile(member).read()
            provenance["sources"].append({"name": toolchain["id"], "url": package["url"],
                                          "sha256": expected, "kind": "guest-binary-package-notices-only"})
        if package_records:
            add("Guest toolchain: " + toolchain["familyName"], toolchain["version"],
                "Multiple licenses; exact cached archive notices (audit incomplete)",
                "Separately downloaded toolchain; source/complete dependency inventory unresolved",
                package_records, "Pinned package URLs and SHA256: Catalog/catalog.json")
        blockers.append(f"Guest toolchain {toolchain['id']}: exact redistributed archive notices, "
                        "bundled dependencies and corresponding source not yet verified "
                        f"({len(toolchain.get('packages', []))} pinned packages).")
    for extension in sorted((Path.home() / "RunfernBuild/pkgs").glob("extension-*.vsix")):
        with zipfile.ZipFile(extension) as archive:
            files = {p: archive.read(p) for p in archive.namelist()
                     if re.match(r"^(copying|copyright|licen[cs]e|notice|thirdparty)", Path(p).name.lower())
                     and not p.endswith("/")}
            manifest = json.loads(archive.read("extension/package.json"))
        identity = manifest["publisher"] + "." + manifest["name"]
        add("Editor extension: " + identity, manifest["version"],
            "See exact VSIX notices; redistribution review unresolved",
            "Separately downloaded guest editor extension", files,
            "Local release artifact: " + extension.name)
        provenance.setdefault("extensions", []).append({
            "id": identity, "version": manifest["version"], "sha256": digest(extension.read_bytes())})
    blockers.append("Editor extensions (including ms-python.python): exact downloaded VSIX versions, "
                    "license/third-party notices and redistribution terms are not inventoried.")
    blockers.append("GPL/LGPL distribution terms for combined Runfern/QEMU and any Apple/TestFlight/"
                    "App Store restrictions require explicit legal compatibility review; sign-only "
                    "and no-JIT do not remove QEMU's GPL or LGPL obligations. No clearance inferred.")
    add("Runfern", VERSION, "MIT", "Application and guest agent/extension",
        {"LICENSE": (ROOT / "LICENSE").read_bytes()}, f"Runfern repository LICENSE (release {VERSION})")
    # Avoid leaving obsolete notice files when a dependency set shrinks.
    names = {n["file"] for n in notices}
    for old in RES.glob("notice-*.txt"):
        if old.name not in names:
            old.unlink()
    index = {"format": 1, "release": VERSION, "notices": notices,
             "status": "BLOCKED", "blockers": sorted(set(blockers))}
    provenance["runtimeFiles"] = {
        path.relative_to(ROOT).as_posix(): digest(path.read_bytes())
        for directory in ("Vendor/QEMU", "Vendor/JIT")
        for path in sorted((ROOT / directory).rglob("*"))
        if path.is_file() and path.name != ".DS_Store"}
    (RES / "license-index.json").write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n")
    (OUT / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    (OUT / "blockers.json").write_text(json.dumps(index["blockers"], indent=2) + "\n")
    evidence = {"format": 1, "release": VERSION, "status": "BLOCKED",
                "notices": {notice["file"]: notice["sha256"] for notice in notices},
                "provenance": provenance}
    (RES / "license-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    for path in RES.glob("*"):
        source_entries[f"notices/{path.name}"] = path.read_bytes()
    source_entries["provenance.json"] = (OUT / "provenance.json").read_bytes()
    source_entries["blockers.json"] = (OUT / "blockers.json").read_bytes()
    (OUT / "source-inputs.json").write_text(json.dumps(
        {name: digest(data) for name, data in sorted(source_entries.items())}, indent=2) + "\n")
    source_entries["source-inputs.json"] = (OUT / "source-inputs.json").read_bytes()
    write_tar(OUT / SOURCE_ARCHIVE, source_entries)
    artifact_names = [SOURCE_ARCHIVE, "blockers.json",
                      "provenance.json", "source-inputs.json"]
    (OUT / "SHA256SUMS").write_text("".join(
        f"{digest((OUT / name).read_bytes())}  {name}\n" for name in artifact_names))
    artifacts = {"format": 1, "release": VERSION, "status": "BLOCKED",
                 "sha256": {name: digest((OUT / name).read_bytes())
                            for name in artifact_names + ["SHA256SUMS"]}}
    (Path(__file__).parent / "release-artifacts.json").write_text(json.dumps(artifacts, indent=2) + "\n")
    print(f"{len(notices)} exact notice resources; source inputs: {OUT}")
    print(f"{len(index['blockers'])} open findings in blockers.json; "
          "release builds need them resolved or signed off in clearance.json.")


if __name__ == "__main__":
    main()
