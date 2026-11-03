import hashlib
import io
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

import build_image
import image_evidence
import test_image


class ImageEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.image_id = "debian-12-arm64"
        self.build = self.root / self.image_id
        self.bundle = self.build / "bundle"
        self.bundle.mkdir(parents=True)
        self.editor = build_image.EDITOR
        self.image_manifest = {"ideVersion": self.editor["version"], "kernelVersion": "test-kernel"}
        (self.bundle / "image.json").write_text(json.dumps(self.image_manifest))
        for name in ("disk.qcow2", "vmlinuz", "initrd.img"):
            (self.bundle / name).write_bytes(b"fixture")
        image_evidence.write_archive(self.build / f"{self.image_id}.runfernimage",
                                     {path.name: path for path in self.bundle.iterdir()})
        evidence = self.root / "evidence"
        (evidence / "notices/package").mkdir(parents=True)
        (evidence / "sources/package").mkdir(parents=True)
        (evidence / "notices/package/LICENSE.txt").write_text("Fixture legal document")
        (evidence / "sources/package/source.tar").write_bytes(b"Fixture corresponding source")
        inventory = {"format": 1, "manager": "apt",
            "packages": [{"name": "fixture", "version": "1", "source": "fixture", "sourceVersion": "1",
                          "sourceIdentity": "fixture=1",
                          "notices": [{"file": "notices/package/LICENSE.txt"}]}],
            "sources": {"fixture=1": {"files": {"sources/package/source.tar":
                                                image_evidence.digest(evidence / "sources/package/source.tar")}}},
            "editor": self.editor, "files": image_evidence.source_files(evidence)}
        image_evidence.write_json(evidence / "inventory.json", inventory)
        image_evidence.package(self.build, self.image_id, evidence, build_image.BASES[self.image_id],
                               self.editor, {"commit": "0" * 40, "dirty": False})

    def tearDown(self):
        self.temporary.cleanup()

    def test_complete_evidence_passes(self):
        image_evidence.verify(self.build, self.image_id)

    def test_corrupted_source_asset_fails(self):
        asset = next(self.build.glob("*.sources-*.tar"))
        with asset.open("ab") as output:
            output.write(b"corruption")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            image_evidence.verify(self.build, self.image_id)

    def test_missing_source_asset_fails(self):
        next(self.build.glob("*.sources-*.tar")).unlink()
        with self.assertRaises(FileNotFoundError):
            image_evidence.verify(self.build, self.image_id)

    def test_publication_needs_actual_smoke_test(self):
        with self.assertRaisesRegex(ValueError, "actual agent"):
            image_evidence.verify(self.build, self.image_id, publication=True)
        manifest_path = self.build / f"{self.image_id}.evidence.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["smokeTest"] = {"kernelVersion": "test-kernel", "editorHTTPStatus": 200,
                                "toolchains": ["python-3", "nodejs-24", "rust", "zig"]}
        image_evidence.write_json(manifest_path, manifest)
        image_evidence.verify(self.build, self.image_id, publication=True)
        manifest["smokeTest"]["editorHTTPStatus"] = 503
        image_evidence.write_json(manifest_path, manifest)
        with self.assertRaisesRegex(ValueError, "actual agent"):
            image_evidence.verify(self.build, self.image_id, publication=True)

    def test_uncommitted_sources_cannot_be_published(self):
        manifest_path = self.build / f"{self.image_id}.evidence.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["sourceRevision"]["dirty"] = True
        image_evidence.write_json(manifest_path, manifest)
        with self.assertRaisesRegex(ValueError, "committed"):
            image_evidence.verify(self.build, self.image_id, publication=True)

    def test_asset_size_threshold_is_strict(self):
        size = next(self.build.glob("*.sources-*.tar")).stat().st_size
        with patch.object(image_evidence, "MAX_ASSET", size):
            with self.assertRaisesRegex(ValueError, "exceeds GitHub"):
                image_evidence.verify(self.build, self.image_id)

    def test_unsafe_paths_are_rejected(self):
        for name in ("../source", "/source", "sources/../secret", "./source"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                image_evidence.safe_path(name)

    def test_existing_package_cache_is_rehashed(self):
        data = b"verified"
        checksum = hashlib.sha256(data).hexdigest()
        (self.root / f"{checksum}.tar").write_bytes(b"corrupted")
        with patch.object(test_image, "CACHE", self.root):
            with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                test_image.fetch_verified({"sha256": checksum, "format": "tar", "url": "https://example.invalid"})

    def test_offered_bases_are_pinned(self):
        catalog = json.loads((build_image.HERE.parents[1] / "Catalog/catalog.json").read_text())
        self.assertEqual(set(build_image.BASES), {image["id"] for image in catalog["baseImages"]})
        for base in build_image.BASES.values():
            self.assertNotRegex(base["url"], r"/(latest|current)/")
            algorithm = "sha512" if "sha512" in base else "sha256"
            self.assertEqual(len(base[algorithm]), hashlib.new(algorithm).digest_size * 2)

    def test_vsix_contains_exact_mit_license(self):
        import zipfile
        with zipfile.ZipFile(io.BytesIO(build_image.runfern_extension_vsix())) as archive:
            self.assertEqual(archive.read("extension/LICENSE.txt"),
                             (build_image.HERE.parents[1] / "LICENSE").read_bytes())
            self.assertEqual(json.loads(archive.read("extension/package.json"))["license"], "MIT")

    def test_dsc_checksum_fields_are_preserved(self):
        fields = image_evidence.deb_source_fields(
            "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\nSource: fixture\nVersion: 1\n"
            "Checksums-Sha256:\n abc 3 source.tar\n def 4 patch.tar\n")
        self.assertEqual(fields["Source"], "fixture")
        self.assertEqual(fields["Checksums-Sha256"].splitlines(), ["abc 3 source.tar", "def 4 patch.tar"])

    def test_signature_armor_cannot_override_package_version(self):
        fields = image_evidence.deb_source_fields(
            "Source: db5.3\nVersion: 5.3.28+dfsg2-7\n"
            "-----BEGIN PGP SIGNATURE-----\nVersion: GnuPG v1\n\nsignature\n-----END PGP SIGNATURE-----\n")
        self.assertEqual(fields["Version"], "5.3.28+dfsg2-7")

    def test_slimming_preserves_essential_boot_chain_and_selected_kernel(self):
        packages = [{"name": name, "version": "1"} for name in
                    ("grub-common", "grub-efi-arm64-signed", "linux-image-6.1-arm64",
                     "linux-image-6.1-cloud-arm64", "cloud-init", "git")]
        with patch.object(image_evidence, "apt_packages", return_value=packages), \
                patch.object(image_evidence.subprocess, "run") as run, \
                patch.object(image_evidence, "command", return_value="6.1-cloud-arm64"), \
                patch.object(pathlib.Path, "is_dir", return_value=True):
            image_evidence.slim("apt", "6.1-arm64")
        purge = run.call_args.args[0]
        self.assertIn("cloud-init", purge)
        self.assertIn("linux-image-6.1-cloud-arm64", purge)
        self.assertNotIn("grub-common", purge)
        self.assertNotIn("grub-efi-arm64-signed", purge)
        self.assertNotIn("linux-image-6.1-arm64", purge)
        preseed = next(call for call in run.call_args_list if call.args[0] == ["debconf-set-selections"])
        self.assertEqual(preseed.kwargs["input"],
                         "linux-image-6.1-cloud-arm64 linux-image-6.1-cloud-arm64/prerm/removing-running-kernel boolean false\n")

    def test_customizer_survives_removing_cloud_init(self):
        config = json.loads(build_image.user_data(build_image.BASES[self.image_id]).split("\n", 1)[1])
        launcher = config["runcmd"][0][2]
        self.assertIn("systemd-run --unit=runfern-customize --no-block", launcher)
        self.assertIn("StandardOutput=journal+console", launcher)
        self.assertIn("customize.sh || poweroff", launcher)


if __name__ == "__main__":
    unittest.main()
