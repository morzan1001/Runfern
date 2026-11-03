import hashlib
import io
import json
import pathlib
import tempfile
import unittest
import zipfile
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
        packages = [{"name": name, "version": "1", "source": "linux", "sourceVersion": "1"} for name in
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

    def test_slimming_removes_only_obsolete_kernel_development_packages(self):
        packages = [{"name": name, "version": version, "source": "linux", "sourceVersion": version}
                    for name, version in (
                        ("linux-image-7.0.0-42-generic", "42"),
                        ("linux-modules-7.0.0-42-generic", "42"),
                        ("linux-headers-7.0.0-42", "42"),
                        ("linux-headers-7.0.0-42-generic", "42"),
                        ("linux-headers-7.0.0-38", "38"),
                        ("linux-headers-7.0.0-38-generic", "38"),
                        ("linux-tools-7.0.0-38-generic", "38"),
                        ("linux-libc-dev", "42"))]
        with patch.object(image_evidence, "apt_packages", return_value=packages), \
                patch.object(image_evidence.subprocess, "run") as run, \
                patch.object(image_evidence, "command", return_value="7.0.0-38-generic"), \
                patch.object(pathlib.Path, "is_dir", return_value=True):
            image_evidence.slim("apt", "7.0.0-42-generic")
        self.assertEqual(run.call_args.args[0][5:], [
            "linux-headers-7.0.0-38", "linux-headers-7.0.0-38-generic", "linux-tools-7.0.0-38-generic"])

    def test_fedora_running_kernel_exception_is_limited_to_superseded_build_kernel(self):
        old = "6.19.10-300.fc44"
        selected = "6.19.13-300.fc44"
        packages = [{"name": name, "version": "0:" + version, "architecture": "aarch64"}
                    for name, version in (("kernel-core", old), ("kernel-modules-core", old),
                                          ("kernel-core", selected), ("kernel-modules-core", selected))]
        for running in (old, selected):
            with self.subTest(running=running), \
                    patch.object(image_evidence, "rpm_packages", return_value=packages), \
                    patch.object(image_evidence.subprocess, "run") as run, \
                    patch.object(image_evidence, "command", return_value=running + ".aarch64"), \
                    patch.object(pathlib.Path, "is_dir", return_value=True):
                image_evidence.slim("dnf", selected + ".aarch64")
                removal = run.call_args.args[0]
                self.assertEqual("--setopt=protect_running_kernel=False" in removal, running == old)
                self.assertIn("kernel-core-" + old + ".aarch64", removal)
                self.assertNotIn("kernel-core-" + selected + ".aarch64", removal)

    def test_certificate_notices_include_exact_sources_and_pinned_license_texts(self):
        package = {"name": "ca-certificates", "version": "1", "sourceRPM": "ca-certificates-1.src.rpm",
                   "license": "MIT AND GPL-2.0-or-later"}
        def download(url, target, checksum):
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("Pinned standard license text")
        with patch.object(image_evidence, "rpm_source", return_value=self.root / "source.src.rpm"), \
                patch.object(image_evidence.subprocess, "check_output",
                             return_value=b"Mozilla Public\nLicense, v. 2.0\nOriginal copyright notice"), \
                patch.object(image_evidence, "fetch", side_effect=download) as fetch, \
                patch.object(image_evidence, "verify_digest"), \
                patch.object(image_evidence, "command", return_value=""):
            notices = image_evidence.copy_notices(package, "dnf", self.root, {})
        self.assertEqual(len(notices), 7)
        self.assertEqual(sum(notice.get("sourceRPM") == package["sourceRPM"] for notice in notices), 4)
        self.assertEqual({notice["sourceURL"] for notice in notices if "sourceURL" in notice},
                         {image_evidence.LICENSE_TEXT_URL + name + ".txt"
                          for name in ("MIT", "GPL-2.0-or-later", "MPL-2.0")})
        self.assertEqual({call.args[2] for call in fetch.call_args_list},
                         {image_evidence.LICENSE_TEXTS[name] for name in ("MIT", "GPL-2.0-or-later", "MPL-2.0")})
        package["license"] = "Unreviewed"
        with self.assertRaisesRegex(ValueError, "Unreviewed"):
            image_evidence.ca_certificate_notices(package, self.root)

    def test_rpm_digest_success_without_signature_is_not_source_verification(self):
        source = self.root / "fixture-1.src.rpm"
        source.write_bytes(b"fixture")
        with patch.object(image_evidence, "command", return_value="digests OK"):
            with self.assertRaisesRegex(ValueError, "no verified distribution signature"):
                image_evidence.rpm_source({"sourceRPM": source.name}, self.root)

    def test_directory_only_rpm_metadata_does_not_excuse_unlicensed_files(self):
        package = {"name": "cmake-filesystem", "version": "1", "sourceRPM": "cmake-1.src.rpm",
                   "license": "BSD-3-Clause"}
        with patch.object(image_evidence, "command",
                          side_effect=["", "/usr/share/cmake\t40755"]):
            notices = image_evidence.copy_notices(package, "dnf", self.root, {})
        self.assertEqual(package["kind"], "directory-metadata")
        self.assertEqual(len(notices), 1)
        with patch.object(image_evidence, "command",
                          side_effect=["", "/usr/share/cmake/actual-code\t100644"]), \
                patch.object(image_evidence, "source_rpm_notices", return_value=[]):
            with self.assertRaisesRegex(ValueError, "No installed copyright"):
                image_evidence.copy_notices(package, "dnf", self.root, {})

    def test_missing_binary_notices_are_collected_from_verified_exact_sources(self):
        package = {"name": "container-selinux", "sourceRPM": "container-selinux-1.src.rpm"}
        def extract(args, stdout, check):
            self.assertTrue(check)
            stdout.write(b"nested source archive fixture")
        with patch.object(image_evidence, "rpm_source", return_value=self.root / "exact.src.rpm"), \
                patch.object(image_evidence, "command",
                             side_effect=["source.tar.gz", "source.tar.gz", "upstream/LICENSE"]), \
                patch.object(image_evidence.subprocess, "run", side_effect=extract), \
                patch.object(image_evidence.subprocess, "check_output", return_value=b"Original license text"):
            notices = image_evidence.source_rpm_notices(package, self.root)
        self.assertEqual(len(notices), 1)
        self.assertEqual(notices[0].read_bytes(), b"Original license text")

    def test_repository_metadata_supplement_requires_matching_source_license(self):
        package = {"name": "fedora-gpg-keys", "sourceRPM": "fedora-repos-44-2.src.rpm", "license": "MIT"}
        with patch.object(image_evidence, "rpm_source", return_value=self.root / "exact.src.rpm"), \
                patch.object(image_evidence, "command", return_value="fedora-repos.spec"), \
                patch.object(image_evidence.subprocess, "check_output", return_value=b"License: Unknown\n"):
            with self.assertRaisesRegex(ValueError, "source license differs"):
                image_evidence.source_rpm_notices(package, self.root)

    def test_source_archive_uses_installed_signing_key_and_verifies_before_caching(self):
        package = {"name": "crun", "sourceRPM": "crun-1.28-1.fc44.src.rpm"}
        with patch.object(image_evidence, "command", side_effect=[
                "RSA/SHA256, Key ID dbfcf71c6d9f90a6", "RSA Signature: OK", package["sourceRPM"]]), \
                patch.object(image_evidence.urllib.request, "urlopen", return_value=io.BytesIO(b"source")) as fetch:
            source = image_evidence.rpm_source(package, self.root)
        self.assertEqual(source.read_bytes(), b"source")
        self.assertEqual(fetch.call_args.args[0],
                         "https://kojipkgs.fedoraproject.org/packages/crun/1.28/1.fc44/"
                         "data/signed/6d9f90a6/src/crun-1.28-1.fc44.src.rpm")
        self.assertFalse(source.with_name(source.name + ".download").exists())

    def test_public_domain_notice_preserves_original_source_declaration(self):
        package = {"name": "filesystem", "sourceRPM": "filesystem-3.18-52.fc44.src.rpm",
                   "license": "LicenseRef-Fedora-Public-Domain"}
        statement = b"License: LicenseRef-Fedora-Public-Domain\n"
        with patch.object(image_evidence, "rpm_source", return_value=self.root / "exact.src.rpm"), \
                patch.object(image_evidence, "command", return_value="filesystem.spec"), \
                patch.object(image_evidence.subprocess, "check_output", return_value=statement):
            notices = image_evidence.source_rpm_notices(package, self.root)
        self.assertEqual(len(notices), 1)
        self.assertEqual(notices[0].read_bytes(), statement)

    def test_kernel_header_notices_preserve_original_copyright_and_source_names(self):
        package = {"name": "kernel-headers", "sourceRPM": "kernel-headers-7.2.4-200.fc44.src.rpm",
                   "license": "((GPL-2.0-only WITH Linux-syscall-note) OR BSD-2-Clause) AND BSD-3-Clause "
                              "AND CDDL-1.0 AND Linux-OpenIB AND GPL-1.0-or-later AND GPL-2.0-or-later "
                              "AND LGPL-2.0-or-later AND LGPL-2.1-only AND LGPL-2.1-or-later AND MIT"}
        header = self.root / "original.h"
        header.write_text("/* SPDX-License-Identifier: GPL-2.0-only WITH Linux-syscall-note\n"
                          " * Copyright original upstream author */\n")
        nested = self.root / "headers.tar"
        image_evidence.write_archive(nested, {"headers/include/uapi.h": header, "headers/asm/other.h": header})
        def extract(args, stdout, check):
            self.assertTrue(check)
            stdout.write(nested.read_bytes())
        with patch.object(image_evidence, "rpm_source", return_value=self.root / "exact.src.rpm"), \
                patch.object(image_evidence.subprocess, "check_output",
                             return_value=("License: " + package["license"] + "\n").encode()), \
                patch.object(image_evidence, "license_texts", return_value=[]) as licenses, \
                patch.object(image_evidence.subprocess, "run", side_effect=extract), \
                patch.object(image_evidence, "command", side_effect=[
                    "headers.tar.xz", "headers.tar.xz", "headers/include/uapi.h\nheaders/asm/other.h"]):
            notices = image_evidence.source_rpm_notices(package, self.root)
        self.assertEqual(licenses.call_args.args[0],
                         set(image_evidence.LICENSE_TEXTS) - {"MPL-2.0", "Artistic-1.0-Perl", "Artistic-2.0"})
        text = notices[-1].read_text()
        self.assertIn("headers.tar.xz:headers/include/uapi.h", text)
        self.assertIn("headers.tar.xz:headers/asm/other.h", text)
        self.assertEqual(text.count(header.read_text()), 2)
        with self.assertRaisesRegex(ValueError, "Unreviewed"):
            image_evidence.license_texts({"Unknown-License"}, self.root)

    def test_kernel_header_source_license_mismatch_blocks_collection(self):
        package = {"name": "kernel-headers", "sourceRPM": "kernel-headers-7.2.4-200.fc44.src.rpm",
                   "license": "GPL-2.0-only WITH Linux-syscall-note"}
        with patch.object(image_evidence, "rpm_source", return_value=self.root / "exact.src.rpm"), \
                patch.object(image_evidence.subprocess, "check_output", return_value=b"License: MIT\n"):
            with self.assertRaisesRegex(ValueError, "source license differs"):
                image_evidence.source_rpm_notices(package, self.root)

    def test_kernel_header_license_texts_alone_do_not_replace_original_notices(self):
        package = {"name": "kernel-headers", "sourceRPM": "kernel-headers-7.2.4-200.fc44.src.rpm",
                   "license": "GPL-2.0-only WITH Linux-syscall-note"}
        with patch.object(image_evidence, "rpm_source", return_value=self.root / "exact.src.rpm"), \
                patch.object(image_evidence.subprocess, "check_output",
                             return_value=("License: " + package["license"] + "\n").encode()), \
                patch.object(image_evidence, "license_texts", return_value=[]), \
                patch.object(image_evidence, "command", return_value="kernel-headers.spec"):
            with self.assertRaisesRegex(ValueError, "no original header notices"):
                image_evidence.source_rpm_notices(package, self.root)

    def test_perl_embedded_notices_preserve_original_terms_and_exact_declaration(self):
        package = {"name": "perl-Carp", "sourceRPM": "perl-Carp-1.54-521.fc44.src.rpm",
                   "license": "GPL-1.0-or-later OR Artistic-1.0-Perl"}
        module = self.root / "Carp.pm"
        module.write_text("=head1 COPYRIGHT\nCopyright original author\n=head1 LICENSE\n"
                          "Redistributable under the same terms as Perl itself.\n")
        nested = self.root / "perl.tar"
        image_evidence.write_archive(nested, {"Carp/lib/Carp.pm": module, "Carp/README": module,
                                            "Carp/data/table.ucm": module})
        def extract(args, stdout, check):
            stdout.write(nested.read_bytes())
        with patch.object(image_evidence, "rpm_source", return_value=self.root / "exact.src.rpm"), \
                patch.object(image_evidence.subprocess, "check_output",
                             return_value=("License: Artistic-2.0\n%package -n perl-Carp\nLicense: "
                                           + package["license"] + "\n").encode()), \
                patch.object(image_evidence, "license_texts", return_value=[]) as licenses, \
                patch.object(image_evidence.subprocess, "run", side_effect=extract), \
                patch.object(image_evidence, "command", side_effect=[
                    "Carp.tar.gz", "Carp.tar.gz", "Carp/lib/Carp.pm\nCarp/README"]):
            notices = image_evidence.source_rpm_notices(package, self.root)
        self.assertEqual(licenses.call_args.args[0], {"GPL-1.0-or-later", "Artistic-1.0-Perl"})
        self.assertEqual(notices[-1].read_text().count(module.read_text()), 3)
        package["license"] = "MIT"
        with patch.object(image_evidence, "rpm_source", return_value=self.root / "exact.src.rpm"), \
                patch.object(image_evidence.subprocess, "check_output", return_value=b"License: Unknown\n"):
            with self.assertRaisesRegex(ValueError, "source license differs"):
                image_evidence.source_rpm_notices(package, self.root)

    def test_embedded_source_reader_supports_zip_without_extracting_paths(self):
        path = self.root / "source.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Module/lib/Module.pm", "Original copyright")
        values = [(name, stream.read()) for name, stream in image_evidence.original_source_files(path)]
        self.assertEqual(values, [("Module/lib/Module.pm", b"Original copyright")])

    def test_perl_standard_texts_alone_do_not_replace_original_copyright(self):
        package = {"name": "perl-Carp", "sourceRPM": "perl-Carp-1.54-521.fc44.src.rpm",
                   "license": "GPL-1.0-or-later OR Artistic-1.0-Perl"}
        with patch.object(image_evidence, "rpm_source", return_value=self.root / "exact.src.rpm"), \
                patch.object(image_evidence.subprocess, "check_output",
                             return_value=("License: " + package["license"] + "\n").encode()), \
                patch.object(image_evidence, "license_texts", return_value=[]), \
                patch.object(image_evidence, "command", return_value="perl-Carp.spec"):
            with self.assertRaisesRegex(ValueError, "no original copyright"):
                image_evidence.source_rpm_notices(package, self.root)

    def test_customizer_survives_removing_cloud_init(self):
        config = json.loads(build_image.user_data(build_image.BASES[self.image_id]).split("\n", 1)[1])
        launcher = config["runcmd"][0][2]
        self.assertIn("systemd-run --unit=runfern-customize --no-block", launcher)
        self.assertIn("StandardOutput=journal+console", launcher)
        self.assertIn("customize.sh || poweroff", launcher)


if __name__ == "__main__":
    unittest.main()
