import Foundation

/// Host-side endpoints of one VM. Kept short: Unix socket paths are limited to 104 bytes.
nonisolated struct QEMUSockets: Sendable {
    let directory: URL
    var agent: URL { directory.appending(path: "a") }
    var monitor: URL { directory.appending(path: "q") }
    /// `sun_path` holds 104 bytes including the terminating zero.
    static let maximumPathLength = 103

    static func make() throws -> QEMUSockets {
        #if targetEnvironment(simulator)
        // The simulator's container path is too long for socket addresses; the host's /tmp is reachable.
        let base = URL(filePath: "/tmp", directoryHint: .isDirectory)
        #else
        let base = URL.temporaryDirectory
        #endif
        let directory = base.appending(path: "r\(String(UUID().uuidString.prefix(4)))", directoryHint: .isDirectory)
        let sockets = QEMUSockets(directory: directory)
        // Checked before QEMU starts: a VM whose monitor cannot be reached could not be stopped again.
        guard [sockets.agent, sockets.monitor].allSatisfy({ $0.path(percentEncoded: false).utf8.count <= maximumPathLength }) else {
            throw UnixSocketTransport.SocketError.pathTooLong
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return sockets
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Builds QEMU's command line for a Runfern environment (Plan 4.1).
///
/// The guest gets only virtio devices: system disk, network with user-mode NAT, the agent's
/// serial port, the working copies and the read-only package folder over 9p, and an entropy source.
/// Nothing is reachable from the local network; forwarded ports bind to 127.0.0.1 only.
nonisolated enum QEMUCommandLine {
    /// Name of the virtio-serial port the GuestAgent opens (`/dev/virtio-ports/<name>`).
    static let agentPortName = "nrw.cyber.runfern.agent"
    static let guestIDEPort = 8080
    /// Block node of the first environment's disk; later environments get new nodes (see `QEMUMachines`).
    static let initialDiskNode = "sys0"

    /// A qcow2 node for an environment's overlay, as JSON for `-blockdev` and `blockdev-add`.
    static func diskNode(_ name: String, overlay: URL) -> String {
        let node: [String: Any] = [
            "driver": "qcow2", "node-name": name, "discard": "unmap", "detect-zeroes": "unmap",
            "file": ["driver": "file", "filename": path(overlay)],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: node, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func arguments(configuration: MachineConfiguration, bundle: ImageBundle, kernelCommandLine: String,
                          sockets: QEMUSockets, hostIDEPort: Int, consoleLog: URL,
                          backend: QEMUBackend = .interpreter) -> [String] {
        [
            "-nodefaults", "-no-user-config",
            "-display", "none",
            "-machine", "virt",
            // A plain ARMv8.0 core: features like pointer authentication are expensive to interpret.
            "-cpu", "cortex-a72",
            // A larger translation cache keeps more interpreted code ready (VS Code's server is large).
            "-accel", "tcg,thread=multi," + backend.accelOptions,
            "-smp", "\(configuration.cpuCount)",
            "-m", "\(configuration.memoryMB)",
            "-kernel", path(bundle.kernel),
            "-initrd", path(bundle.initrd),
            // Speculation mitigations only cost time in an emulated CPU.
            "-append", kernelCommandLine + " mitigations=off",
            "-blockdev", diskNode(initialDiskNode, overlay: configuration.overlay),
            "-device", "virtio-blk-pci,id=sysdisk,drive=\(initialDiskNode)",
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(hostIDEPort)-:\(guestIDEPort)",
            "-device", "virtio-net-pci,netdev=net0,romfile=",
            "-device", "virtio-serial-pci",
            "-chardev", "socket,id=agent,server=on,wait=off,path=\(option(sockets.agent))",
            "-device", "virtserialport,chardev=agent,name=\(agentPortName)",
            "-qmp", "unix:\(option(sockets.monitor)),server=on,wait=off",
            // Verified toolchain archives and extensions; the guest can only read them.
            "-fsdev", "local,id=packages,security_model=none,readonly=on,path=\(option(AppPaths.packages))",
            "-device", "virtio-9p-pci,fsdev=packages,mount_tag=\(PackageLibrary.mountTag)",
            "-device", "virtio-rng-pci",
            "-serial", "file:\(path(consoleLog))",
            // Powering off parks QEMU instead of ending it, so the next environment can start on it.
            "-no-shutdown",
        ]
    }

    private static func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    /// QEMU separates options with commas; a literal comma is written twice.
    private static func option(_ url: URL) -> String {
        path(url).replacingOccurrences(of: ",", with: ",,")
    }
}
