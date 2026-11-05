import shutil
import tarfile
import struct
import unittest
import json
from unittest.mock import patch
from pathlib import Path

import prepare
import verify
from macho import fingerprint


class LicenseCollectorTests(unittest.TestCase):
    def setUp(self):
        self.work = prepare.OUT / "test-work"
        self.work.mkdir(parents=True, exist_ok=False)

    def tearDown(self):
        shutil.rmtree(self.work)

    def test_legal_documents_are_verbatim(self):
        text = b"Copyright (c) Example Author\n\nPermission is hereby granted.\n"
        self.assertEqual(prepare.legal_records({"nested/LICENSE-MIT": text}),
                         {"nested/LICENSE-MIT": text.decode()})

    def test_cpp_notice_does_not_include_preprocessor_or_code(self):
        notice = "/* Copyright (c) Example Author */\n"
        records = prepare.legal_records({"a.h": (notice + "#define A 42\nint a;\n").encode()})
        self.assertEqual(records["a.h"], notice)

    def test_multiple_comments_and_copyrights_are_retained(self):
        text = "// Copyright (c) A\n// Licensed under MIT\n\n/* Copyright (c) B */\n"
        self.assertEqual(prepare.legal_records({"a.rs": (text + "fn main() {}\n").encode()})["a.rs"], text)

    def test_python_notices_and_no_binary_decoding(self):
        notice = "# Copyright (c) Example\n# Licensed under MIT\n"
        records = prepare.legal_records({"a.py": (notice + "x = 42\n").encode(), "LICENSE.bin": b"\0a"})
        self.assertEqual(records, {"a.py": notice})

    def test_deterministic_archive_and_modes(self):
        a, b = self.work / "a.tar.gz", self.work / "b.tar.gz"
        prepare.write_tar(a, {"b.txt": b"b", "a.sh": b"#!/bin/sh\n"})
        prepare.write_tar(b, {"a.sh": b"#!/bin/sh\n", "b.txt": b"b"})
        self.assertEqual(a.read_bytes(), b.read_bytes())
        with tarfile.open(a) as archive:
            self.assertEqual(archive.getnames(), ["a.sh", "b.txt"])
            self.assertEqual(archive.getmember("a.sh").mode, 0o755)
            self.assertEqual(archive.getmember("b.txt").mtime, 0)

    def test_cached_download_checksum_fails_closed(self):
        path = self.work / "cached"
        path.write_bytes(b"changed")
        with self.assertRaises(ValueError):
            prepare.fetch("https://example.invalid", path, prepare.digest(b"expected"))

    def test_verifier_fails_closed(self):
        with self.assertRaises(ValueError):
            verify.require(False, "missing source")

    def test_clearance_preflight_rejects_unresolved_findings(self):
        index = {"format": 1, "release": verify.VERSION, "status": "BLOCKED",
                 "blockers": ["Missing corresponding source"], "notices": [{}]}
        (self.work / "license-index.json").write_text(json.dumps(index))
        with patch.object(verify, "RES", self.work), patch("sys.argv", [
            "verify.py", "--notices-only", "--require-clearance"
        ]), self.assertRaisesRegex(ValueError, "RELEASE BLOCKED"):
            verify.main()

    def test_sign_off_applies_only_to_its_variant_and_exact_findings(self):
        clearance = self.work / "clearance.json"
        clearance.write_text(json.dumps({"format": 1, "flavors": {"no-jit": [
            {"reason": "Accepted by the maintainer", "blockers": ["QEMU license review"]}]}}))
        findings = ["QEMU license review"]
        self.assertEqual(verify.unresolved(findings, "no-jit", clearance), [])
        self.assertEqual(verify.unresolved(findings, "jit", clearance), findings)
        self.assertEqual(verify.unresolved(["QEMU license review (changed)"], "no-jit", clearance),
                         ["QEMU license review (changed)"])
        clearance.write_text(json.dumps({"format": 1, "flavors": {"no-jit": [{"blockers": findings}]}}))
        with self.assertRaisesRegex(ValueError, "reason"):
            verify.unresolved(findings, "no-jit", clearance)

    def test_cleared_preflight_allows_further_checks_without_claiming_release_approval(self):
        text = "Copyright Example\n" + "Permission is hereby granted.\n" * 4
        notice = {"file": "notice-example.txt", "sha256": verify.sha(text.encode())}
        index = {"format": 1, "release": verify.VERSION, "status": "VERIFIED",
                 "blockers": [], "notices": [notice]}
        evidence = {"format": 1, "release": verify.VERSION, "status": "VERIFIED",
                    "notices": {notice["file"]: notice["sha256"]}}
        (self.work / notice["file"]).write_text(text)
        (self.work / "license-index.json").write_text(json.dumps(index))
        (self.work / "license-evidence.json").write_text(json.dumps(evidence))
        with patch.object(verify, "RES", self.work), patch("sys.argv", [
            "verify.py", "--notices-only", "--require-clearance"
        ]):
            verify.main()

    def test_macho_signing_normalization_and_code_mutation(self):
        def binary(signed):
            section = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT",
                                  512, 4, 512, 0, 0, 0, 0, 0, 0, 0)
            text = struct.pack("<II16sQQQQIIII", 0x19, 152, b"__TEXT",
                               0, 4096, 0, 516, 7, 5, 1, 0) + section
            linkedit = struct.pack("<II16sQQQQIIII", 0x19, 72, b"__LINKEDIT",
                                   4096, 4096 if signed else 0, 516, 16 if signed else 0,
                                   7, 1, 0, 0)
            commands = text + linkedit
            if signed:
                commands += struct.pack("<IIII", 0x1D, 16, 528, 4)
            header = struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 6,
                                 3 if signed else 2, len(commands), 0, 0)
            result = header + commands
            result += b"\0" * (512 - len(result)) + b"CODE"
            return result + b"\0" * 12 + b"SIGN" if signed else result
        unsigned, signed = binary(False), binary(True)
        self.assertEqual(fingerprint(unsigned), fingerprint(signed))
        self.assertNotEqual(fingerprint(unsigned), fingerprint(unsigned[:-1] + b"X"))
        with self.assertRaises(ValueError):
            fingerprint(b"unknown binary")


if __name__ == "__main__":
    unittest.main()
