# Runfern release-license evidence

This is an evidence collector and integrity gate, not a legal opinion. The App Store
(no-JIT) build is released: its open findings are signed off by the maintainer in
`clearance.json`, including the GPL/LGPL terms of the embedded QEMU and libraries.
The JIT build is a separate sideload distribution; CI does not build it until its
findings are resolved or signed off.

## Reproduce locally

From the repository root, with Python 3.11+, macOS `otool`/`dwarfdump`, the actual
UTM build trees, and internet access to public upstream sources:

```sh
python3 Tools/Licenses/prepare.py --utm "$HOME/RunfernBuild/UTM"
python3 Tools/Licenses/verify.py
cd build/licenses && shasum -a 256 -c SHA256SUMS
```

The last two commands establish **artifact integrity only**. The fail-closed release
gate must also inspect the resources in the exact exported/archived application:

If source collection already completed, `python3 Tools/Licenses/seal.py` refreshes
the CI/macOS validation metadata and scripts inside that existing source-input
archive without claiming new source correspondence or clearing any findings.
It first verifies the existing archive/member hashes and unchanged native inputs.
This is useful when native collection cannot be repeated due to local host resource
limits; it does not resolve missing crate licenses or guest sources.

```sh
python3 Tools/Licenses/verify.py --release --app build/Runfern.xcarchive/Products/Applications/Runfern.app
```

### CI interface (Python 3.11+, no third-party Python dependencies)

Clean Linux CI checks the committed exact notice texts and evidence without needing
macOS, local UTM sources, proprietary SDKs or native build products:

```sh
python3 Tools/Licenses/verify.py --notices-only
python3 Tools/Licenses/verify.py --notices-only --release
```

The second command fails on unresolved licensing evidence; `--notices-only` can never
serve as full release approval. To validate an unpacked native runtime package and
its accompanying source inputs on Linux:

`--notices-only --require-clearance` is a fail-fast preflight for unresolved findings,
used before CI release builds. It permits further verification only after findings are
resolved, but never replaces the full runtime/source and actual-app release checks.

Findings that the maintainer accepts for one variant are listed in `clearance.json` under
`flavors.no-jit` or `flavors.jit`, each group with its reason. Entries must match the
finding texts in `license-index.json` exactly, so any new or changed finding blocks the
release again. `--require-clearance` and `--release` apply the sign-offs for `--flavor`
(default `no-jit`). All current findings are signed off for the App Store
build; the JIT build has no sign-offs yet.

```sh
python3 Tools/Licenses/verify.py --runtime-root build/native-runtime --artifacts build/licenses
python3 Tools/Licenses/verify.py --runtime-root build/native-runtime --artifacts build/licenses --release
```

`--runtime-root` contains `Vendor/QEMU/{iphoneos,iphonesimulator}`, `Vendor/JIT`, and
the complete `Runfern/Resources/Licenses` directory (notice texts plus both manifests).
The entire targeted vendor file inventory, including the unused tvOS StikJIT slice,
is hashed; unused slices do not silently escape native-package license verification.
`--artifacts` must contain **every file pinned by**
`Tools/Licenses/release-artifacts.json`: source-input archive, source-input member
manifest, provenance, blockers and SHA256SUMS. No binary archive hash is assumed:
the unpacked binaries are checked individually against committed evidence.

On macOS, verify the actual device `.app`, not just the vendor inputs:

```sh
python3 Tools/Licenses/verify.py --artifacts build/licenses --app PATH/Runfern.app --flavor no-jit
python3 Tools/Licenses/verify.py --artifacts build/licenses --app PATH/Runfern.app --flavor jit --release
```

The `.app` mode checks all exact bundled notices/index and the entire embedded
framework inventory against audited Mach-O UUIDs **and signature-independent code/data
fingerprints**. Signing metadata and alignment padding are normalized, not executable
sections; modified code cannot pass by retaining the UUID. Raw unsigned vendor hashes
are not incorrectly compared with re-signed framework bytes.
No-JIT forbids JIT frameworks/helper; JIT expects both QEMU engines
and StikJIT. These identity checks do not prove compile-time source correspondence
or create license clearance. Exit status is zero only for the requested integrity
level; `--release` requires every finding to be resolved or signed off for the flavor.
Do not upload to TestFlight while the gate fails. Keep privately signed archives separate from public re-signable IPA
packaging; no license exception is inferred from removing signatures/profiles.

It fails while `build/licenses/blockers.json` lists findings that `clearance.json`
does not sign off. Never change the manifest to `VERIFIED` without obtaining and
implementing the missing evidence; record accepted findings as sign-offs instead.
Do not ship an artifact solely because checksum verification passes.

## Outputs and provenance

* `Runfern/Resources/Licenses/license-index.json` and `notice-*.txt`: searchable,
  selectable actual legal documents and verbatim source copyright/license headers.
  These live under the app's Xcode synchronized resource group; filenames are unique
  so flattening cannot collide. `--app` verifies the packaged bytes.
* `Runfern/Resources/Licenses/license-evidence.json`: committed public provenance and
  notice/binary hashes, usable on clean CI.
* `Tools/Licenses/release-artifacts.json`: committed hashes of the locally prepared
  corresponding-source input outputs. It contains no binary or third-party source tree.
* `build/licenses/Runfern-<version>-source-inputs.tar.gz`: deterministic **source-input**
  bundle, not yet certified complete corresponding source. It contains original
  source archives for all three QEMU builds, file-level local overrides, public UTM
  source (including patches and build scripts), Runfern QEMU/JIT build scripts,
  actual configure/meson settings where present, libucontext source, StikJIT source
  with prebuilt static libraries removed, idevice source and every registry crate in
  its locked dependency graph, notices and audit metadata.
* `provenance.json`: source URLs, source SHA256 values, build/vendor Mach-O UUID
  checks, vendor hashes/link lists, logo comparison, guest editor versions and
  locally available package/VSIX notice evidence.
* `source-inputs.json`, `SHA256SUMS`: per-member and artifact integrity checks.
* `blockers.json`: actionable unresolved release findings.
* `upstream/`: public download cache, never commit this or the archive/source trees.

The source archive has normalized ordering, timestamps, owners and permissions.
Upstream notice texts remain byte-identical; whitespace checks are disabled only for those
verbatim documents in `.gitattributes`.
Given identical source inputs and build configurations, repeated generation produces
identical bytes. Build configuration may contain local source paths; review these
before public distribution. Executable shell scripts retain execute permission.
Restore upstream archives into the matching `UTM/build-*-arm64` directories, apply
UTM patches/data using the bundled scripts, then overlay the matching `overrides/`
files to recover the audited source inputs. Local overrides take precedence.
Use the bundled `Tools/QEMU/build-qemu-ios.sh` for interpreter platforms; the trimmed
UTM script also supports `-p ios -a arm64` for JIT. Obtain the matching Apple SDK
separately: proprietary SDK files are not redistributed.

## Scope and known missing evidence

The actual framework link closure includes QEMU 10.0.12-utm, GLib/GIO/GObject/GModule
2.83.0, libffi 3.5.0, GNU libiconv 1.16, gettext/libintl 0.22.5, pixman 0.38.0,
libslirp 4.9.1 and Zstandard 1.5.2. QEMU statically links libucontext at
`9b1d8f01a6e99166f9808c79966abe10786de8b6`, PCRE2 10.44 (including its checksum-pinned
Meson wrap patch), and libfdt/dtc at `b6910bec11614980a21e46fbccc35934b671bd81`.
These subproject sources are also included for all three platforms. System libraries
are not copied.
The GPL/LGPL full texts and source per-file notices are retained, not replaced with
an approximate component label. Source archives include build-tool licensing too.
QEMU firmware/ROM and test source attribution is excluded from the in-app emulator
notice: those are not shipped in `Vendor/QEMU/*.framework`. The original source
archive still preserves their license files; the emulator's own `LICENSE` explains
the distinction.

StikJIT 2.0.1 is pinned to `b3e01a30ded4cd0b27cf1b6bd42f123bbdf49c3a`.
Its repository includes precompiled idevice archives **without their exact source
commit/lockfile/features**. Those are not assumed to be idevice v0.1.68. Runfern's
separate idevice archive is pinned to v0.1.68 (`d32c8189c51c2789496b0768039419c3705498c3`);
all 359 registry packages in its Cargo.lock are checksum-verified and retained as a
conservative superset. This is not a reconstructed static-library link map.
Missing crate legal texts are explicit blockers, never filled with an invented MIT
copyright or generic guessed license.
When a crate omits legal files but supplies a clean `.cargo_vcs_info.json` SHA and
public GitHub repository, exact legal files are retrieved from that revision and
recorded as supplements with their URLs/hashes. A missing repository or dirty VCS
record is not guessed away.

Devicon SVGs are compared with exact public source files at a recorded revision.
The MIT notice is separate from project trademarks; it grants no trademark rights.
Downloaded guest Linux distributions and toolchains are not embedded app components.
Exact cached toolchain/extension legal documents are included where available, but
each shipped image still needs installed package/version inventory, distribution
copyright notices, kernel/GPL corresponding source packages and pinned build inputs.
Editor source notices do not establish complete third-party notices of the binary.
Unpinned `latest` cloud/editor downloads and uninventoried marketplace extensions
are blockers, not evidence of compliance.

The existing QEMU builds have no compile-time source digest attestation. Matching
vendor/sysroot UUIDs proves where frameworks were copied from, not that current
source files produced those frameworks. The generated source inputs preserve the
available evidence, but a rebuild with a source manifest and build record is needed
before certifying corresponding source. These tooling changes do not rebuild the app.

## Source-distribution obligations

Publish complete verified corresponding source alongside each binary release rather
than relying on third-party upstream links or this documentation as a source offer.
Include modifications, all necessary build/install scripts and any required
installation/relinking materials. Review the combined application's GPL obligations,
LGPL replacement/relinking rights (including signing restrictions), and MPL source
availability for the exact covered StikJIT files. Retain applicable notices in guest
archives as well as the app. App attribution alone does not discharge source or
redistribution obligations.
