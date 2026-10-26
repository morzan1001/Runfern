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

iPadOS runs generated code only while a debugger is attached. On devices with the Trusted
Execution Monitor, the debugger must also prepare the code region: QEMU stops at `brk #0x69` with
the region in x0/x1 when it allocates it, the debugger writes to the region and moves the pc past
the breakpoint. StikDebug and StikJIT do this with their bundled `legacy.js` script and then detach.

For tests without StikDebug, `run-jit-test.sh` plays that part with LLDB (`lldb_txm_jit.py`):

```sh
Tools/QEMU/run-jit-test.sh <device-udid> /tmp/jit detach -- -qemu-boot-test debian-12-arm64-v4
Tools/QEMU/run-jit-test.sh <device-udid> /tmp/e2e detach -- -e2e-test
```

Preparing the 256 MB code cache over USB takes about 80 s; `-jitCacheMB 32` shortens it for tests.

## Built-in JIT

The `builtIn` method needs nothing but a pairing file of the iPad (`Tools/JIT/export-pairing-file.sh`
copies the Mac's record):

- `RunfernTunnel` is a packet tunnel that routes only `10.7.0.1` and turns TCP/UDP packets between
  `10.7.0.0` and `10.7.0.1` around, so the iPad reaches its own developer services. It runs only
  while JIT is being enabled, never on demand, and stops itself after 10 minutes.
- `RunfernJITHelper` runs StikJIT (`Vendor/JIT`, MPL-2.0) with its bundled `legacy.js` and attaches
  only to Runfern's own process. The pairing file travels to it in memory and exists on disk only
  for the duration of the request.
- The imported pairing file stays in Runfern's container with complete file protection, excluded
  from backups, and never appears in logs, support reports, or exports.

## Licensing

QEMU is GPLv2. Distributing the app with these frameworks requires providing the corresponding
source, including UTM's patches and the trimmed build script.
