# Runfern

Linux and a VS Code-based editor on your iPad. Runfern runs an ARM64 Linux VM locally,
opens OpenVSCode Server in the app, and keeps projects in local folders. Choose tools and editor
extensions per project, or reuse a preset.

<p>
  <img src="Design/Screenshots/new-project.png" width="49%" alt="Runfern project setup on iPad">
  <img src="Design/Screenshots/project.png" width="49%" alt="A sample project's Linux environment and installed tools">
</p>

Project setup and a sample project, captured in the iPad simulator.

## Getting started

Requires iPadOS 27 or later. Debian 12 is available through the signed catalog, with
[verified image, source and license downloads](https://github.com/morzan1001/Runfern/releases/tag/debian-12-arm64-v1).
The app remains a source preview: public app builds await completion of the native dependency
license evidence. The interpreter variant does not need JIT.

Linux bases and tools need an initial download. Installed environments run locally.
Built-in JIT needs Developer Mode, pairing and Network Extension signing; ordinary sideload
signing may require an external JIT method instead.

## Building

Build [QEMU](Tools/QEMU/README.md), then fetch the JIT dependencies if needed:

```sh
Tools/JIT/build-jit-vendor.sh
RUNFERN_INTERNAL_BUILD=1 Tools/Build/build.sh jit
RUNFERN_INTERNAL_BUILD=1 Tools/Build/build.sh appstore-archive
```

See [builds and release automation](Tools/Build/README.md) for signing, versioning and the
manually approved TestFlight pipeline. [Catalog publishing](Tools/Catalog/README.md)
uses signed, checksum-pinned downloads.

## Licenses

Runfern's own code is [MIT](LICENSE). Embedded dependencies retain their licenses, including
QEMU (GPLv2), StikJIT (MPL-2.0, JIT builds only), idevice (MIT plus its dependencies), and
devicon language icons (MIT; project names and logos remain their owners' trademarks).

The app's **Settings > Components and Licenses** contains third-party notices. Binary
distribution also requires corresponding source and dependency license texts. Passing a build
does not establish compatibility with Apple's App Store terms.
See the [license evidence and remaining blockers](Tools/Licenses/README.md).
