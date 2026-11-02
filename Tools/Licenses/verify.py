#!/usr/bin/env python3
"""Fail-closed license artifact verification; --release also requires resolved evidence."""
import argparse
import hashlib
import json
import subprocess
import tarfile
from pathlib import Path
from macho import fingerprint

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/licenses"
RES = ROOT / "Runfern/Resources/Licenses"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--require-clearance", action="store_true",
                        help="Preflight unresolved findings; not full release approval")
    parser.add_argument("--notices-only", action="store_true",
                        help="Linux-safe committed-notice integrity check; not source/release approval")
    parser.add_argument("--artifacts", type=Path, default=OUT,
                        help="Directory containing corresponding source artifact and audit outputs")
    parser.add_argument("--runtime-root", type=Path, default=ROOT,
                        help="Root of unpacked native runtime, containing Vendor/QEMU and Vendor/JIT")
    parser.add_argument("--app", type=Path, help="Check notices in an actual exported .app (no build/upload)")
    parser.add_argument("--flavor", choices=("no-jit", "jit"), default="no-jit")
    args = parser.parse_args()
    output = args.artifacts
    index = json.loads((RES / "license-index.json").read_text())
    require(index["format"] == 1 and index["release"] == "0.0.1", "Unexpected license manifest")
    require(index["notices"], "Empty notice manifest")
    if args.require_clearance:
        require(index["status"] == "VERIFIED" and not index["blockers"],
                "RELEASE BLOCKED:\n- " + "\n- ".join(index["blockers"]))
    seen = set()
    for notice in index["notices"]:
        filename = notice["file"]
        require(filename == Path(filename).name and filename not in seen, "Unsafe/duplicate resource filename")
        seen.add(filename)
        path = RES / filename
        require(path.is_file(), f"Missing notice: {filename}")
        require(sha(path.read_bytes()) == notice["sha256"], f"Notice checksum mismatch: {filename}")
        require(len(path.read_text().strip()) > 80, f"Empty/incomplete notice: {filename}")
        if args.app:
            locations = [args.app / filename, args.app / "Licenses" / filename,
                         args.app / "Resources/Licenses" / filename]
            require(any(p.is_file() and sha(p.read_bytes()) == notice["sha256"] for p in locations),
                    f"App is missing exact notice resource: {filename}")
    if args.app:
        locations = [args.app / "license-index.json", args.app / "Licenses/license-index.json",
                     args.app / "Resources/Licenses/license-index.json"]
        require(any(p.is_file() and p.read_bytes() == (RES / "license-index.json").read_bytes()
                    for p in locations), "App license index missing/different")
    require({p.name for p in RES.glob("notice-*.txt")} == seen, "Unexpected/unindexed notice resources")
    evidence = json.loads((RES / "license-evidence.json").read_text())
    require(evidence["format"] == 1 and evidence["release"] == index["release"]
            and evidence["status"] == index["status"], "Notice/evidence release status mismatch")
    for notice in index["notices"]:
        require(notice["sha256"] == evidence["notices"][notice["file"]],
                f"Notice/evidence manifest mismatch: {notice['file']}")
    if args.notices_only:
        require(not args.app, "--notices-only cannot replace actual --app validation")
        print(f"PASS: {len(seen)} committed notice resources (Linux-safe).")
        if args.release:
            require(index["status"] == "VERIFIED" and not index["blockers"],
                    "RELEASE BLOCKED:\n- " + "\n- ".join(index["blockers"]))
            raise ValueError("Release approval also requires source artifacts and actual runtime/app verification")
        print("Notice integrity only. NOT release approval.")
        return
    artifact_manifest = json.loads((ROOT / "Tools/Licenses/release-artifacts.json").read_text())
    require(artifact_manifest["format"] == 1 and artifact_manifest["release"] == index["release"]
            and artifact_manifest["status"] == index["status"], "Source artifact manifest release mismatch")
    require("Runfern-0.0.1-source-inputs.tar.gz" in artifact_manifest["sha256"], "Source artifact not pinned")
    for name, expected in artifact_manifest["sha256"].items():
        require(name == Path(name).name, "Unsafe artifact filename")
        require((output / name).is_file() and sha((output / name).read_bytes()) == expected,
                f"Missing/changed release source artifact: {name}")
    for line in (output / "SHA256SUMS").read_text().splitlines():
        expected, name = line.split("  ", 1)
        require(name == Path(name).name, "Unsafe checksum filename")
        require((output / name).is_file() and sha((output / name).read_bytes()) == expected,
                f"Artifact checksum mismatch: {name}")
    inputs = json.loads((output / "source-inputs.json").read_text())
    with tarfile.open(output / "Runfern-0.0.1-source-inputs.tar.gz") as archive:
        members = archive.getmembers()
        require(len(members) == len(inputs) + 1, "Missing/extra source archive members")
        for member in members:
            require(member.isfile() and not member.name.startswith("/")
                    and ".." not in Path(member.name).parts, "Unsafe source archive member")
            data = archive.extractfile(member).read()
            expected = sha((output / "source-inputs.json").read_bytes()) if member.name == "source-inputs.json" else inputs.get(member.name)
            require(sha(data) == expected, f"Source checksum mismatch: {member.name}")
            require(not member.name.endswith((".a", ".dylib", ".ipa", ".qcow2")),
                    f"Binary in source bundle: {member.name}")
    provenance = json.loads((output / "provenance.json").read_text())
    require(provenance == evidence["provenance"], "Source artifact/committed binary evidence differs")
    require(provenance["sources"] and provenance["binaries"] and provenance["logos"], "Missing audit evidence")
    if args.app:
        expected = {}
        for binary in provenance["binaries"]:
            if ("uuid" not in binary or ".framework/" not in binary["path"] or "/iphonesimulator/" in binary["path"]
                    or "/tvos-arm64/" in binary["path"]):
                continue
            name = Path(binary["path"]).name
            if args.flavor == "no-jit" and (name.endswith("-jit") or name == "StikJIT"):
                continue
            expected[name] = binary
        actual = list(args.app.rglob("*.framework"))
        require(len(actual) == len(expected) and {p.stem for p in actual} == set(expected),
                f"Actual embedded framework inventory differs from {args.flavor} evidence")
        for framework in actual:
            binary = expected[framework.stem]
            require("uuid" in binary, f"Missing compiled binary provenance UUID: {framework.stem}")
            uuid = subprocess.check_output(["dwarfdump", "--uuid", str(framework / framework.stem)],
                                           text=True).split()[1]
            require(uuid == binary["uuid"], f"Embedded Mach-O UUID changed: {framework.stem}")
            require(fingerprint((framework / framework.stem).read_bytes()) == binary["codeFingerprint"],
                    f"Embedded executable code/data differs from audited binary: {framework.stem}")
        if args.flavor == "no-jit":
            require(not list(args.app.rglob("RunfernJITHelper.appex")), "No-JIT app embeds JIT helper")
    else:
        native_resources = args.runtime_root / "Runfern/Resources/Licenses"
        for filename in seen | {"license-index.json", "license-evidence.json"}:
            path = native_resources / filename
            require(path.is_file() and path.read_bytes() == (RES / filename).read_bytes(),
                    f"Native runtime package missing exact bundled notice/manifest: {filename}")
        native_files = {
            path.relative_to(args.runtime_root).as_posix(): sha(path.read_bytes())
            for directory in ("Vendor/QEMU", "Vendor/JIT")
            for path in (args.runtime_root / directory).rglob("*")
            if path.is_file() and path.name != ".DS_Store"}
        require(native_files == provenance["runtimeFiles"], "Native runtime file inventory/hashes changed")
        for binary in provenance["binaries"]:
            path = args.runtime_root / binary["path"]
            require(path.is_file() and sha(path.read_bytes()) == binary["sha256"],
                    f"Native runtime changed since source audit: {binary['path']}")
        expected_qemu = {b["path"] for b in provenance["binaries"] if b["path"].startswith("Vendor/QEMU/")}
        actual_qemu = {(framework / framework.stem).relative_to(args.runtime_root).as_posix()
                       for framework in (args.runtime_root / "Vendor/QEMU").glob("*/*.framework")}
        require(actual_qemu == expected_qemu, "QEMU framework inventory changed; regenerate the source audit")
        expected_jit = {b["path"].split("/")[2] for b in provenance["binaries"]
                        if b["path"].startswith("Vendor/JIT/")}
        actual_jit = {path.name for path in (args.runtime_root / "Vendor/JIT").glob("*.xcframework")}
        require(expected_jit == actual_jit, "JIT native runtime inventory differs from source audit")
    for logo in provenance["logos"]:
        require(sha((ROOT / logo["path"]).read_bytes()) == logo["sha256"], f"Logo changed: {logo['path']}")
    print(f"PASS: {len(seen)} exact notice resources and source-input artifact checksums.")
    if args.release:
        blockers = json.loads((output / "blockers.json").read_text())
        require(blockers == index["blockers"], "Resource/artifact blocker lists differ")
        require(index["status"] == "VERIFIED" and not blockers,
                "RELEASE BLOCKED:\n- " + "\n- ".join(blockers))
        print("PASS: release evidence and actual app resources verified.")
    else:
        print("Artifact integrity only. NOT release approval; run --release --app PATH.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, IndexError, subprocess.CalledProcessError,
            json.JSONDecodeError, tarfile.TarError) as error:
        raise SystemExit(f"FAIL: {error}")
