# Signed catalog

The app bundles `Catalog/catalog.json` and checks the copy on `main` for updates. It accepts only
Ed25519 signatures matching `publisherKey` in `Runfern/Catalog/CatalogStore.swift`, and only a
higher `catalogVersion`. Downloads are HTTPS and SHA-256 pinned.

The initial catalog is version 1 and includes Debian 12/13, Ubuntu 24.04/26.04, and Fedora 44
ARM64 images, all in the release `catalog-v1`. It may change in place until the first app release
(tag `v*`); after that, every change needs a higher `catalogVersion` so installed apps accept it.

`CATALOG_SIGNING_KEY` belongs only in the `catalog` GitHub environment, restricted to the `main`
branch. Never commit the private key. Check it locally with:

```sh
Tools/Catalog/sign-catalog.sh --check-key
Tools/Catalog/verify-catalog.sh
```

**Sign Catalog** increments and signs the current catalog without building images.
**Publish Linux Base** builds the requested bases, publishes their immutable release assets,
then produces the signed catalog and a GitHub-signed pull request. It explicitly starts Catalog
CI for that PR and merges only after successful checks through normal branch protection.
Merged publisher branches are removed only if their head still matches the checked commit.
Publisher write permissions are limited to the protected `catalog` job; workflow defaults remain
read-only. Both workflows retain `signed-catalog` as an artifact. **Sign Catalog** still requires
submitting its artifact through a PR manually.

All images of a catalog version are assets of one release, `catalog-v<N>`. Published images are not replaced.
The publisher verifies each actual image, not a global clearance flag. Cloud images and the
editor are immutable, checksum-verified inputs. Installed packages, copyright documents, exact
Debian source packages or signed Fedora source RPMs from the Koji archive, editor/Node sources and Runfern build
inputs are attached to the image release. Missing evidence or a failed boot/editor/toolchain
smoke test stops publication. Unresolved native app/JIT license findings remain separate.
Fedora's certificate package lacks standalone RPM license files. Its original notices are
collected from the exact, signature-verified source RPM, alongside checksum-pinned standard
MIT, GPLv2 and MPL 2.0 texts; the distribution's license label does not replace source notices.
Other missing RPM notices are recovered from original legal files in verified source packages;
directory-only packages retain their RPM license declaration and exact source identity.
Public-domain packages retain the exact signed-source declaration rather than invented license texts.
Noncopyrightable configuration packages likewise retain their original declarations and files.
Signed shim packages retain both the signing-input SRPM and the exact distribution-signed
compiled-source SRPM identified by their original macros; notices come from the actual C source.
Exported kernel headers retain their original copyright/SPDX notices, complete declared license
texts and the Linux syscall exception. Standard supplements record their immutable SPDX source.
Perl modules also retain embedded text-source copyright notices and complete declared license texts,
including encoding tables and module-specific terms. Binary subpackage declarations must match
the signed source spec.
Source transfers retry temporary transport failures with bounded HTTPS-only requests; checksums
and RPM signatures are verified only after complete transfers. Partial files never enter the cache.
Rebuilding an already published base requires the explicit `rebuild` option; the catalog keeps
only its newest build, so an older environment cannot download its base again.

Publishing manually:

```sh
python3 Tools/GuestImage/build_image.py debian-12-arm64
python3 Tools/GuestImage/test_image.py debian-12-arm64
Tools/Catalog/publish-image.sh debian-12-arm64
python3 Tools/Catalog/catalog_release.py finish
Tools/Catalog/sign-catalog.sh
```

Commit JSON and signature together through a pull request. Guest images need their own license
and source compliance before distribution. GitHub limits each release asset to less than 2 GiB.

`RUNFERN_IMAGE_BUILD_ROOT` selects an isolated output/cache directory for all image tools.
Image archives retain the four-file USTAR format the app reads. Source companions are separate
archives, split below GitHub's asset limit. Within Linux, legal documents and the exact package
inventory are available at `/usr/share/runfern/licenses`.

If main advances while an automated catalog PR is checked, publishing fails rather than
bypassing protection. Re-run the failed publisher job to reuse its immutable image assets.

After failed builds, `reuse_run` may reference an earlier main **Publish Linux Base** run.
Only successful, unexpired artifacts from its signed ancestor commit are reused, with full
image/source/legal verification and matching original smoke evidence. Failed images are built
again; fork workflows, pending builds and expired artifacts are rejected.
