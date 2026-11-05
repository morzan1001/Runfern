#!/usr/bin/env python3
"""Seal existing checksum-verified source inputs with current validation tooling."""
import io
import json
import subprocess
import tarfile
import zipfile

from prepare import ROOT, RES, OUT, SOURCE_ARCHIVE, VERSION, digest, write_tar
from macho import fingerprint


def main():
    for line in (OUT / "SHA256SUMS").read_text().splitlines():
        expected, name = line.split("  ", 1)
        if digest((OUT / name).read_bytes()) != expected:
            raise ValueError(f"Existing source artifact changed: {name}")
    old_inputs = json.loads((OUT / "source-inputs.json").read_text())
    entries = {}
    with tarfile.open(OUT / SOURCE_ARCHIVE, mode="r|gz") as archive:
        for member in archive:
            if not member.isfile():
                raise ValueError("Unexpected source archive member")
            data = archive.extractfile(member).read()
            if member.name == "source-inputs.json":
                if data != (OUT / "source-inputs.json").read_bytes():
                    raise ValueError("Embedded source input manifest differs")
                continue
            if digest(data) != old_inputs.get(member.name):
                raise ValueError(f"Existing source input changed: {member.name}")
            entries[member.name] = data
    if len(entries) != len(old_inputs):
        raise ValueError("Existing source archive is incomplete")
    provenance = json.loads((OUT / "provenance.json").read_text())
    index = json.loads((RES / "license-index.json").read_text())
    if index["status"] != "BLOCKED" or not index["blockers"]:
        raise ValueError("Metadata refresh cannot confer release approval")
    for notice in index["notices"]:
        if digest((RES / notice["file"]).read_bytes()) != notice["sha256"]:
            raise ValueError(f"Notice changed: {notice['file']}")
    for binary in provenance["binaries"]:
        if digest((ROOT / binary["path"]).read_bytes()) != binary["sha256"]:
            raise ValueError(f"Native input changed: {binary['path']}")
    release = OUT / "upstream/StikJIT-release.zip"
    expected_release = "c376687326a785f5ed1da8caca08adc709b56919019dd751bca059b92b175d95"
    if digest(release.read_bytes()) != expected_release:
        raise ValueError("StikJIT release cache checksum mismatch")
    missing = []
    with zipfile.ZipFile(release) as archive:
        for filename in ("StikJIT", "legacy.js", "universal.js"):
            relative = f"Vendor/JIT/StikJIT.xcframework/tvos-arm64/StikJIT.framework/{filename}"
            path = ROOT / relative
            released = archive.read(relative.removeprefix("Vendor/JIT/"))
            if path.read_bytes() != released:
                raise ValueError(f"tvOS StikJIT does not match pinned public release: {filename}")
            if not any(b["path"] == relative for b in provenance["binaries"]):
                missing.append({"path": relative, "sha256": digest(released),
                                "releaseSHA256": expected_release})
    insertion = next(i for i, b in enumerate(provenance["binaries"])
                     if b["path"].startswith("Vendor/JIT/IDevice"))
    provenance["binaries"][insertion:insertion] = missing
    for binary in provenance["binaries"]:
        path = ROOT / binary["path"]
        if path.parent.suffix == ".framework" and path.name == path.parent.stem:
            uuid = subprocess.check_output(["dwarfdump", "--uuid", str(path)], text=True).split()[1]
            if "uuid" in binary and uuid != binary["uuid"]:
                raise ValueError(f"Native UUID changed: {binary['path']}")
            binary["uuid"] = uuid
            binary["codeFingerprint"] = fingerprint(path.read_bytes())
    provenance["runtimeFiles"] = {
        path.relative_to(ROOT).as_posix(): digest(path.read_bytes())
        for directory in ("Vendor/QEMU", "Vendor/JIT")
        for path in sorted((ROOT / directory).rglob("*"))
        if path.is_file() and path.name != ".DS_Store"}
    (OUT / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    evidence = {"format": 1, "release": VERSION, "status": "BLOCKED",
                "notices": {n["file"]: n["sha256"] for n in index["notices"]},
                "provenance": provenance}
    (RES / "license-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    for path in (ROOT / "Tools/Licenses").iterdir():
        if path.is_file() and path.suffix in (".py", ".md"):
            entries[f"build/Tools/Licenses/{path.name}"] = path.read_bytes()
    for path in RES.iterdir():
        if path.is_file():
            entries[f"notices/{path.name}"] = path.read_bytes()
    entries["provenance.json"] = (OUT / "provenance.json").read_bytes()
    (OUT / "source-inputs.json").write_text(json.dumps(
        {name: digest(data) for name, data in sorted(entries.items())}, indent=2) + "\n")
    entries["source-inputs.json"] = (OUT / "source-inputs.json").read_bytes()
    write_tar(OUT / SOURCE_ARCHIVE, entries)
    names = [SOURCE_ARCHIVE, "blockers.json", "provenance.json", "source-inputs.json"]
    (OUT / "SHA256SUMS").write_text("".join(
        f"{digest((OUT / name).read_bytes())}  {name}\n" for name in names))
    artifacts = {"format": 1, "release": VERSION, "status": "BLOCKED",
                 "sha256": {name: digest((OUT / name).read_bytes()) for name in names + ["SHA256SUMS"]}}
    (ROOT / "Tools/Licenses/release-artifacts.json").write_text(json.dumps(artifacts, indent=2) + "\n")
    print("Sealed existing verified source inputs; all unresolved license findings retained.")


if __name__ == "__main__":
    main()
