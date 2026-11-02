# Signed catalog

The app bundles `Catalog/catalog.json` and checks the copy on `main` for updates. It accepts only
Ed25519 signatures matching `publisherKey` in `Runfern/Catalog/CatalogStore.swift`, and only a
higher `catalogVersion`. Downloads are HTTPS and SHA-256 pinned.

`CATALOG_SIGNING_KEY` belongs only in the `catalog` GitHub environment, restricted to the `main`
branch. Never commit the private key. Check it locally with:

```sh
Tools/Catalog/sign-catalog.sh --check-key
Tools/Catalog/verify-catalog.sh
```

**Sign Catalog** increments and signs the current catalog without building images.
**Publish Linux Base** builds the requested bases, publishes their immutable release assets,
then produces the signed catalog. Both workflows save `signed-catalog` as an artifact: download
it and submit both JSON and signature in a pull request to `main`. Neither bypasses branch
protection or writes directly to `main`. Merge only if the catalog version is still newer than
`main`; rerun signing after concurrent changes.

Linux-image releases are named `<id>-v<image version>`. Published images are not replaced.
Image publishing is disabled until `LINUX_IMAGE_LICENSE_CLEARED=true` is set in the protected
`catalog` environment after the image's package, license and source inventories are complete.
Signing a catalog does not grant permission to distribute its images.
Rebuilding an already published base requires the explicit `rebuild` option; the catalog keeps
only its newest build, so an older environment cannot download its base again.

Publishing manually:

```sh
python3 Tools/GuestImage/build_image.py debian-12-arm64
Tools/Catalog/publish-image.sh debian-12-arm64
python3 Tools/Catalog/catalog_release.py finish
Tools/Catalog/sign-catalog.sh
```

Commit JSON and signature together through a pull request. Guest images need their own license
and source compliance before distribution. GitHub limits each release asset to less than 2 GiB.
