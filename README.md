# Runfern

Runfern turns an iPad into a local development machine. It runs a real Linux VM on the device
and opens VS Code full screen, with the project's folder mounted directly. Tools like Python,
Node.js, or Java and VS Code extensions are chosen per project, setups can be saved as presets,
and everything works offline. No cloud, no remote server.

## Repository

| Path | Contents |
| --- | --- |
| `Runfern/` | The iPadOS app (SwiftUI) |
| `RunfernTests/` | Unit tests (Swift Testing) |
| `RunfernJITHelper/`, `RunfernTunnel/`, `RunfernJITShared/` | Built-in JIT: helper and VPN extensions, only in JIT builds |
| `Catalog/` | The signed catalog of Linux bases and tools that apps load |
| `Tools/QEMU/` | Building and embedding QEMU (UTM's fork); see its README |
| `Tools/GuestImage/` | Building the Linux base images |
| `Tools/Catalog/` | Signing the catalog and publishing images |
| `Tools/Build/` | Building the App Store and the JIT variant |
| `Tools/JIT/` | Fetching StikJIT and idevice for JIT builds; creating the pairing file on a computer |
| `Design/` | App icon source |

## Building

1. Build QEMU and place it in `Vendor/QEMU/` (`Tools/QEMU/README.md`). Without it, the app
   builds with a simulated Linux runtime.
2. For JIT builds, fetch StikJIT and idevice: `Tools/JIT/build-jit-vendor.sh`. Built-in JIT also
   needs a pairing file of the iPad, which Runfern creates on iPadOS 27 itself, or
   `Tools/JIT/create-pairing-file.sh` on a computer (`Tools/QEMU/README.md`, “Built-in JIT”).
3. Open `Runfern.xcodeproj` and run the `Runfern` scheme, or build a distributable variant. Run
   from Xcode, Xcode's debugger is attached: with the Built-In JIT method Linux then runs
   interpreted; with StikDebug or External Debugger it stops at QEMU's `brk #0x69` inside
   `qemu_init` unless `Tools/QEMU/lldb_txm_jit.py` answers it. To use Built-In JIT, start Runfern
   from the Home Screen.

```sh
Tools/Build/build.sh appstore   # interpreter only: no JIT code, no extensions
Tools/Build/build.sh jit        # everything, signed for development (sideloading)
```

The script checks that each variant contains exactly what it should.

## Catalog

Apps start with the catalog bundled at build time (`Catalog/catalog.json`) and check
`https://raw.githubusercontent.com/morzan1001/Runfern/main/Catalog/catalog.json` for newer
ones. A catalog is installed only if its Ed25519 signature matches the publisher key built into
the app and its `catalogVersion` is higher than the active one. Every image and package it lists
is pinned to an HTTPS address and a SHA-256 checksum. The `Catalog` workflow checks every change
(`Tools/Catalog/verify-catalog.sh`).

Linux bases are release assets of this repository, one release per build (`<id>-v<version>`).
A new build of a published base gets the next version; published builds are never replaced, so
environments keep the build they were created with.

One-time setup: the publisher key. Its public half is `publisherKey` in
`Runfern/Catalog/CatalogStore.swift`; the private half, `Tools/Catalog/catalog_signing_key`,
never enters the repository. Without one yet, `xcrun swiftc -O Tools/Catalog/sign.swift -o
/tmp/runfern-sign && /tmp/runfern-sign keygen` creates it and prints the public key for
`publisherKey`; only apps built with that key accept catalogs signed with it. Then store the key
as the repository secret `CATALOG_SIGNING_KEY` (Settings > Secrets and variables > Actions):

```sh
Tools/Catalog/sign-catalog.sh --check-key    # the key belongs to publisherKey
gh secret set CATALOG_SIGNING_KEY < Tools/Catalog/catalog_signing_key
```

Publishing: Actions > “Publish Linux Base” > Run workflow on `main`, with the base ids, for
example `debian-12-arm64 ubuntu-24.04-arm64`. The workflow builds each base on an arm64 runner,
uploads it as a release, and pushes the signed catalog to `main`. Apps pick the new catalog up by
themselves and download a base the first time a project needs it.

On a Mac, by hand:

```sh
Tools/GuestImage/build_image.py <id>         # builds Tools/GuestImage/build/<id>/<id>.runfernimage
Tools/Catalog/publish-image.sh <id>          # uploads it as a release and enters it in the catalog
Tools/Catalog/catalog_release.py finish      # raises catalogVersion
Tools/Catalog/sign-catalog.sh                # signs with Tools/Catalog/catalog_signing_key
git commit Catalog && git push
```

Toolchain archives stay with their publishers (python-build-standalone, Node.js, Adoptium,
Gradle); `Tools/Catalog/update_catalog.py` pins new releases.

## Licenses

The language logos in the software picker come from devicon (MIT) and are trademarks of their
respective projects, used only to identify the languages.

Runfern's own code is under the MIT License (`LICENSE`). Builds embed third-party components
that are not part of this repository and keep their licenses: QEMU (GPLv2, including UTM's
patches), its libraries, and, in JIT builds, StikJIT (MPL-2.0) and idevice (MIT, with the Rust
crates it links). Distributing the app requires meeting their terms, in particular providing
QEMU's corresponding source and shipping the license texts.
