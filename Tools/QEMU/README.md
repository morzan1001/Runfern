# QEMU for Runfern

Runfern embeds QEMU 10 (UTM's fork) as frameworks and runs it on a thread inside the app.

## Variants

| Framework | Backend | Embedded in |
| --- | --- | --- |
| `qemu-aarch64-softmmu` | TCTI interpreter, no generated code | every build |
| `qemu-aarch64-softmmu-jit` | TCG JIT with split W^X mapping | `Debug` and `Sideload` (`RUNFERN_JIT = YES`) |

App Store builds (`Release`) contain only the interpreter. Builds with `RUNFERN_JIT = YES` also
compile the JIT code (Swift condition `RUNFERN_JIT`) and embed StikJIT, the JIT helper extension,
and the VPN extension (`embed-qemu.sh`). At runtime the JIT backend is used only if it is embedded,
enabled in Settings, and a debugger is attached when QEMU starts (`QEMUBackend.preferred`);
otherwise the interpreter runs.

`Tools/Build/build.sh appstore|jit` archives and exports either variant and checks its contents.
The `Runfern JIT` scheme runs and archives the `Sideload` configuration from Xcode.

## Building

```sh
Tools/QEMU/build-qemu-ios.sh ~/RunfernBuild/UTM ios-tci ios_simulator-tci ios
Tools/QEMU/install-vendor.sh ~/RunfernBuild/UTM
```

`install-vendor.sh` copies the interpreter builds and their libraries to `Vendor/QEMU/<sdk>/` and
adds the JIT build as `qemu-aarch64-softmmu-jit.framework`.

## JIT on iPadOS

iPadOS runs generated code only while a debugger is attached, and the debugger must prepare the
code region: whenever a debugger is attached on iPadOS 26 or later, QEMU stops at `brk #0x69` with
the region in x0/x1 when it allocates it, the debugger writes to the region and moves the pc past
the breakpoint. StikDebug and StikJIT do this with their bundled `legacy.js` script and then detach.

Only UTM's QEMU `v10.0.12-utm` and later (UTM 5.0.4 and later) contain this breakpoint; with an
older QEMU the debugger would wait forever. `install-vendor.sh` refuses such a build.

For tests without StikDebug, `run-jit-test.sh` plays that part with LLDB (`lldb_txm_jit.py`):

```sh
Tools/QEMU/run-jit-test.sh <device-udid> /tmp/jit detach -- -qemu-boot-test debian-12-arm64-v4
Tools/QEMU/run-jit-test.sh <device-udid> /tmp/e2e detach -- -e2e-test
```

With `lldb_txm_jit.py`, preparing the 256 MB code cache over USB takes about 80 s; `-jitCacheMB 32`
shortens it for tests.

## Built-in JIT

The `builtIn` method needs nothing but a Remote Pairing file (RPPairing) of the iPad: a property
list with `public_key`, `private_key`, `identifier`, and optionally `alt_irk`, as idevice and
StikJIT read it. A lockdown pairing record (`HostID`, `HostCertificate`, … from Finder or
libimobiledevice) does not work. Ways to create the file:

- **On the iPad** (iPadOS 27): Settings › Performance › Create on This iPad…. Runfern advertises
  itself as a pairable host (`_remotepairing-pairable-host._tcp`, idevice's `pairable_host_*`
  functions from `Vendor/JIT/IDevice.xcframework`); the iPad offers “Pair with Runfern-…” under
  Settings › Privacy & Security › Developer Mode and asks for the code Runfern shows.
- **On a computer**: `Tools/JIT/create-pairing-file.sh` pairs over USB (or, with `--wifi`, lets
  the iPad pair with the computer) using idevice's own tools and checks the result against the iPad.
  On Windows, idevice_pair 1.1.0 or iloader 2.4.1 (Manage Pairing File › Export) do the same. Send
  the file to the iPad and import it under Settings › Performance.

The file stops working when the iPad's passcode is changed or removed; create a new one then.

Built-In also needs signing that grants the Network Extension capability (`packet-tunnel-provider`),
in practice Xcode with a paid developer account. AltStore, SideStore, and iloader cannot grant it;
use StikDebug with LocalDevVPN there. iPadOS keeps only one VPN active, so a Built-In attempt
deselects another VPN such as LocalDevVPN.

- `RunfernTunnel` is a packet tunnel that routes only `10.7.0.1` and turns TCP/UDP packets between
  `10.7.0.0` and `10.7.0.1` around, so the iPad reaches its own developer services. It runs only
  while JIT is being enabled, never on demand, stays connected while the iPad sleeps, and stops
  itself after 10 minutes. Meanwhile Runfern keeps the iPad from locking by itself.
- `RunfernJITHelper` runs StikJIT 2.0.1 (`Vendor/JIT`, MPL-2.0) with its bundled `legacy.js`, on
  the fixed Remote Pairing port 49152, and attaches only to Runfern's own process. The pairing file
  travels to it in memory and exists on disk only for the duration of the request. Its progress
  (stages, the code region, the number of prepared pages) goes to the unified log, subsystem
  `nrw.cyber.runfern.jit-helper`; when it fails, Settings › Performance explains the stage.
- The pairing file stays in Runfern's container, reduced to the four keys StikJIT reads, with
  complete file protection, excluded from backups, and never appears in logs, support reports, or
  exports.

## Licensing

QEMU is GPLv2. Distributing the app with these frameworks requires providing the corresponding
source, including UTM's patches and the trimmed build script. JIT builds also contain StikJIT
(MPL-2.0, source at https://github.com/StikDebug/StikJIT/tree/2.0.1) and idevice (MIT, with the
Rust crates it links), whose license texts must ship with the app.
