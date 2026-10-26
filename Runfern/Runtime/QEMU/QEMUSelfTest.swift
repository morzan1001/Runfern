#if DEBUG
import Foundation

/// Step-by-step smoke tests of the embedded QEMU on a device, started with a launch argument.
/// Every step is printed, so a hang shows exactly where it happens.
///
/// - `-qemu-self-test`: QEMU without a guest (load, QMP, quit).
/// - `-qemu-boot-test [image directory]`: boots an installed image through the real adapter, opens the
///   editor endpoint, and shuts the guest down again.
nonisolated enum QEMUSelfTest {
    static let launchArgument = "-qemu-self-test"
    static let bootArgument = "-qemu-boot-test"
    static let switchArgument = "-qemu-switch-test"

    static var isRequested: Bool {
        [launchArgument, bootArgument, switchArgument].contains(where: CommandLine.arguments.contains)
    }

    private static let log = TestLog("QEMUSelfTest")

    private static func step(_ message: String) {
        log.step(message)
    }

    /// The installed directory of the catalog's Debian base, used when no directory is given.
    private static var defaultImageDirectory: String {
        let id = "debian-12-arm64"
        return AppPaths.imageDirectoryName(id, version: Catalog.baseImage(id: id)?.catalogVersion ?? 1)
    }

    static func run() async {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: switchArgument) {
            let next = arguments.index(after: index)
            await switchEnvironments(imageDirectory: next < arguments.endIndex ? arguments[next] : defaultImageDirectory)
            return
        }
        if let index = arguments.firstIndex(of: bootArgument) {
            let next = arguments.index(after: index)
            let imageID = next < arguments.endIndex && !arguments[next].hasPrefix("-") ? arguments[next] : defaultImageDirectory
            await boot(imageID: imageID)
        } else {
            await launchOnly()
        }
    }

    private static func launchOnly() async {
        step("library: \(QEMUBackend.interpreter.library?.path(percentEncoded: false) ?? "missing"), JIT: \(JITSupport.isIncluded ? "included" : "not included"), debugger: \(JITSupport.isDebuggerAttached)")
        do {
            let sockets = try QEMUSockets.make()
            defer { sockets.remove() }
            step("monitor socket: \(sockets.monitor.path(percentEncoded: false))")
            let arguments = ["-nodefaults", "-no-user-config", "-display", "none", "-machine", "none",
                             "-qmp", "unix:\(sockets.monitor.path(percentEncoded: false)),server=on,wait=off"]
            let exit = QEMUExit()
            Task.detached {
                step("qemu_init starting")
                do {
                    exit.record(.success(try await QEMULauncher.run(arguments: arguments)))
                } catch {
                    exit.record(.failure(error as? QEMULauncher.LaunchError ?? .loadFailed("\(error)")))
                }
                step("QEMU returned: \(String(describing: exit.result))")
            }

            let transport = try await UnixSocketTransport.connect(path: sockets.monitor.path(percentEncoded: false),
                                                                  timeout: .seconds(30)) { exit.result == nil }
            step("monitor connected")
            let monitor = QMPClient(transport: transport)
            try await monitor.connect(timeout: .seconds(30))
            step("QMP negotiated")
            try await monitor.execute("query-status")
            step("query-status answered")
            _ = try? await monitor.execute("quit", timeout: .seconds(10))
            step("quit sent")
            let result = await exit.wait(timeout: .seconds(30))
            step("finished: \(String(describing: result))")
        } catch {
            step("FAILED: \(error.localizedDescription) (\(error))")
        }
    }

    private static func boot(imageID: String) async {
        let environmentID = UUID(uuidString: "00000000-0000-0000-0000-00000000B007")!
        let image = AppPaths.images.appending(path: imageID, directoryHint: .isDirectory)
        let workspace = AppPaths.workingCopy(environmentID)
        let configuration = MachineConfiguration(environmentID: environmentID, image: image,
                                                 overlay: AppPaths.overlay(environmentID), workspace: .workingCopy(workspace),
                                                 memoryMB: 3072, cpuCount: 4)
        let console = AppPaths.environment(environmentID).appending(path: "console.log")
        let adapter = QEMUEmulatorAdapter()

        // Mirrors new guest console output, which shows how far Linux got.
        let mirror = Task.detached {
            var offset: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let handle = try? FileHandle(forReadingFrom: console) else { continue }
                defer { try? handle.close() }
                try? handle.seek(toOffset: offset)
                guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }
                offset += UInt64(data.count)
                for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(20) {
                    print("[guest] \(line)")
                }
            }
        }
        defer { mirror.cancel() }

        do {
            step("image: \(try ImageBundle(directory: image).manifest())")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try Data("print('Hello from Runfern')\n".utf8).write(to: workspace.appending(path: "hello.py"))
            // A fresh system disk, so an overlay from an earlier image can't get in the way.
            try? FileManager.default.removeItem(at: console.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: console.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await adapter.createSystemDisk(image: image, overlay: configuration.overlay)
            step("overlay ready, booting with \(QEMUBackend.preferred.rawValue)")
            let endpoint = try await adapter.start(configuration: configuration)
            step("editor reported ready on port \(endpoint.url.port ?? 0)")
            let (_, response) = try await URLSession.shared.data(from: endpoint.url)
            step("editor HTTP status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            try await adapter.verify(configuration: configuration)
            step("health check passed")
            try await adapter.stop(environmentID: environmentID)
            step("guest powered off cleanly")
        } catch {
            step("FAILED: \(error.localizedDescription) (\(error))")
            try? await adapter.stop(environmentID: environmentID)
        }
    }

    /// Starts two environments one after the other in the same app session: the second start swaps
    /// the system disk of the running QEMU instead of loading QEMU again.
    private static func switchEnvironments(imageDirectory: String) async {
        let image = AppPaths.images.appending(path: imageDirectory, directoryHint: .isDirectory)
        let adapter = QEMUEmulatorAdapter()
        let ids = [UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!]
        do {
            for round in 1...2 {
                for id in ids {
                    let workspace = AppPaths.workingCopy(id)
                    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                    let configuration = MachineConfiguration(environmentID: id, image: image, overlay: AppPaths.overlay(id),
                                                             workspace: .workingCopy(workspace), memoryMB: 3072, cpuCount: 4)
                    try await adapter.createSystemDisk(image: image, overlay: configuration.overlay)
                    let started = ContinuousClock.now
                    let endpoint = try await adapter.start(configuration: configuration)
                    let (_, response) = try await URLSession.shared.data(from: endpoint.url)
                    step("round \(round), environment \(id.uuidString.suffix(2)): editor HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) after \((ContinuousClock.now - started).components.seconds) s")
                    try await adapter.verify(configuration: configuration)
                    try await adapter.stop(environmentID: id)
                    step("round \(round), environment \(id.uuidString.suffix(2)): stopped")
                }
            }
            step("switch test passed")
        } catch {
            step("FAILED: \(error.localizedDescription) (\(error))")
        }
    }
}
#endif
