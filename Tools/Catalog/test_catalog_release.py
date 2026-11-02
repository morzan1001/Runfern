import copy
import datetime
import unittest

import catalog_release as release


class CatalogReleaseTests(unittest.TestCase):
    def setUp(self):
        self.catalog = release.load(release.CATALOG)
        self.image = self.catalog["baseImages"][0]
        self.image.pop("source", None)

    def test_published_images_are_pinned_and_immutable(self):
        image_id = self.image["id"]
        version = self.image["catalogVersion"]
        checksum = "a" * 64
        release.set_source(self.catalog, image_id, version, release.release_url(image_id, version), checksum, 123)
        self.assertEqual(release.published_version(self.catalog, image_id, checksum), version)
        with self.assertRaises(release.CatalogError):
            release.next_version(self.catalog, image_id)
        self.assertEqual(release.next_version(self.catalog, image_id, rebuild=True), version + 1)
        with self.assertRaises(release.CatalogError):
            release.set_source(self.catalog, image_id, version, release.release_url(image_id, version), "b" * 64, 123)

    def test_bad_image_metadata_is_rejected(self):
        image_id = self.image["id"]
        version = self.image["catalogVersion"]
        valid = [image_id, version, release.release_url(image_id, version), "a" * 64, 123]
        for index, invalid in [(1, True), (1, 0), (2, "http://example.org/image"), (3, "xyz"), (4, 0)]:
            values = list(valid)
            values[index] = invalid
            with self.subTest(index=index, value=invalid), self.assertRaises(release.CatalogError):
                release.set_source(copy.deepcopy(self.catalog), *values)

    def test_catalog_changes_require_a_higher_version(self):
        previous = release.dump(self.catalog).encode()
        self.catalog["baseImages"][0]["downloadSizeBytes"] += 1
        self.assertIsNotNone(release.version_problem(release.dump(self.catalog).encode(), previous))
        release.finish(self.catalog, datetime.datetime(2026, 11, 2, tzinfo=datetime.timezone.utc))
        self.assertIsNone(release.version_problem(release.dump(self.catalog).encode(), previous))
        self.assertEqual(self.catalog["publishedAt"], "2026-11-02T00:00:00Z")


if __name__ == "__main__":
    unittest.main()
