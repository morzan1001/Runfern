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
| `Tools/JIT/` | Fetching StikJIT for JIT builds |
| `Design/` | App icon source |

## Building

1. Build QEMU and place it in `Vendor/QEMU/` (`Tools/QEMU/README.md`). Without it, the app
   builds with a simulated Linux runtime.
2. For JIT builds, fetch StikJIT: `Tools/JIT/build-jit-vendor.sh`.
3. Open `Runfern.xcodeproj` and run the `Runfern` scheme, or build a distributable variant:

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
is pinned to an HTTPS address and a SHA-256 checksum.

Publishing a new Linux base:

```sh
Tools/GuestImage/build_image.py <id>         # builds Tools/GuestImage/build/<id>/<id>.runfernimage
Tools/Catalog/publish-image.sh <id>          # uploads it as a release asset and enters it in the catalog
# raise catalogVersion in Catalog/catalog.json
Tools/Catalog/sign-catalog.sh                # signs the catalog (needs the private key, never committed)
git commit Catalog && git push
```

Toolchain archives stay with their publishers (python-build-standalone, Node.js, Adoptium,
Gradle); `Tools/Catalog/resolve_toolchains.py` pins new releases.

## Licenses

The language logos in the software picker come from devicon (MIT) and are trademarks of their
respective projects, used only to identify the languages.

Runfern's own code is under the MIT License (`LICENSE`). Builds embed third-party components
that are not part of this repository and keep their licenses: QEMU (GPLv2, including UTM's
patches), its libraries, and, in JIT builds, StikJIT (MPL-2.0). Distributing the app requires
meeting their terms, in particular providing QEMU's corresponding source.
