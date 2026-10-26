import Foundation

/// The embedded QEMU and the environment currently running on it (ADR04).
///
/// QEMU can be loaded only once per app process, so it stays alive for the whole session. Stopping
/// an environment powers Linux off and parks QEMU; starting another environment swaps the system
/// disk of the virtio device (`qom-set … drive`), resets the machine, and boots again. Memory, CPUs,
/// and the Linux base are fixed by the first start of a session.
actor QEMUMachines {
    struct Machine: Sendable {
        let environmentID: UUID
        let agent: GuestAgentClient
        let monitor: QMPClient
        let sessionToken: String
        let hostIDEPort: Int
    }

    /// The QEMU process state that outlives individual environments.
    private struct Instance {
        let agent: GuestAgentClient
        let monitor: QMPClient
        let hostIDEPort: Int
        let sockets: QEMUSockets
        let exit: QEMUExit
        let image: URL
        var diskNode: String
        var nodeSerial: Int
    }

    private static let deviceID = "sysdisk"
    private static let devicePath = "/machine/peripheral/\(deviceID)"

    private var instance: Instance?
    private var machine: Machine?
    private var booting: (environmentID: UUID, task: Task<Machine, Error>)?
    private var forwards: [Int: Int] = [:]
    /// Serves a mounted folder to the running environment; the folder stays accessible meanwhile.
    /// Serves the active project's files to Linux; see `mount(_:agent:)`.
    private var folderServer: (server: NinePServer, files: WorkspaceFiles?)?

    func running(_ id: UUID) -> Machine? {
        machine?.environmentID == id ? machine : nil
    }

    /// Returns the running VM, booting it if needed.
    ///
    /// Booting runs in its own task that a canceled caller stops waiting for but does not stop, so a
    /// later call, for example when setup is resumed, picks up the same machine.
    func boot(_ configuration: MachineConfiguration) async throws -> Machine {
        if let machine {
            if machine.environmentID == configuration.environmentID { return machine }
            // Left running by a finished setup; the app has already ended any session using it.
            try await shutDown(machine.environmentID)
        }
        if let booting {
            guard booting.environmentID == configuration.environmentID else { throw QEMULauncher.LaunchError.alreadyRunning }
            return try await awaitDetached(booting.task)
        }
        let task = Task {
            defer { booting = nil }
            return try await performBoot(configuration)
        }
        booting = (configuration.environmentID, task)
        return try await awaitDetached(task)
    }

    /// Runs `body` against the VM, booting it if needed. The VM keeps running afterwards, so setup
    /// hands its running machine over to `start`.
    func withMachine(_ configuration: MachineConfiguration, _ body: (Machine) async throws -> Void) async throws {
        try await body(try await boot(configuration))
    }

    /// Forwards a guest port to a new loopback port for the preview (IDE09). Repeated requests reuse it.
    func forward(_ guestPort: Int, environmentID: UUID) async throws -> Int {
        guard let machine = running(environmentID) else { throw GuestAgentClient.AgentError.disconnected }
        if let hostPort = forwards[guestPort] { return hostPort }
        let hostPort = try LoopbackPort.free()
        try await machine.monitor.humanMonitor("hostfwd_add net0 tcp:127.0.0.1:\(hostPort)-:\(guestPort)")
        forwards[guestPort] = hostPort
        return hostPort
    }

    /// Powers the guest off and releases the environment's disk; QEMU stays ready for the next start.
    func shutDown(_ id: UUID) async throws {
        guard let machine = running(id), var instance else { return }
        self.machine = nil
        for hostPort in forwards.values {
            try? await instance.monitor.humanMonitor("hostfwd_remove net0 tcp:127.0.0.1:\(hostPort)")
        }
        forwards = [:]

        _ = try? await machine.agent.send(.shutdown, timeout: .seconds(60))
        if !(await waitForStatus("shutdown", on: instance, timeout: .seconds(60))) {
            DiagnosticsLog.record(.warning, .runtime, "Guest did not power off in time; halting the VM")
            _ = try? await instance.monitor.execute("stop")
        }
        stopFolderServer()
        // A placeholder keeps the device attached while no environment's disk is in use.
        instance.nodeSerial += 1
        let placeholder = "idle\(instance.nodeSerial)"
        try await instance.monitor.execute("blockdev-add", arguments: ["driver": "null-co", "node-name": placeholder])
        try await replaceDisk(of: &instance, with: placeholder)
        self.instance = instance
        DiagnosticsLog.record(.info, .runtime, "VM stopped")
    }

    // MARK: Booting

    private func performBoot(_ configuration: MachineConfiguration) async throws -> Machine {
        let bundle = ImageBundle(directory: configuration.image)
        let manifest = try bundle.manifest()
        // An overlay on a different base yields a corrupt file system; refuse instead.
        if let expected = configuration.baseBuildID, manifest.buildID != expected {
            throw ImageBundle.BundleError.baseReplaced
        }
        let consoleLog = AppPaths.environment(configuration.environmentID).appending(path: "console.log")
        try? FileManager.default.removeItem(at: consoleLog)

        var instance: Instance
        if let existing = self.instance {
            guard existing.exit.result == nil, existing.image == configuration.image else {
                throw QEMULauncher.LaunchError.restartRequired
            }
            instance = existing
            try await attach(configuration, to: &instance)
            self.instance = instance
        } else {
            instance = try await launch(configuration, bundle: bundle, manifest: manifest, console: consoleLog)
            self.instance = instance
        }

        let token = SessionToken.generate()
        try await greet(instance.agent, token: token, unless: instance.exit, console: consoleLog)
        try await mount(configuration.workspace, agent: instance.agent)
        let machine = Machine(environmentID: configuration.environmentID, agent: instance.agent,
                              monitor: instance.monitor, sessionToken: token, hostIDEPort: instance.hostIDEPort)
        self.machine = machine
        forwards = [:]
        DiagnosticsLog.record(.info, .runtime, "VM ready")
        return machine
    }

    /// Starts QEMU with the environment's disk; it then serves every later environment of the session.
    private func launch(_ configuration: MachineConfiguration, bundle: ImageBundle, manifest: ImageBundle.Manifest,
                        console: URL) async throws -> Instance {
        let sockets = try QEMUSockets.make()
        let hostIDEPort = try LoopbackPort.free()
        let backend = await JITSupport.backendForLaunch()
        let arguments = QEMUCommandLine.arguments(configuration: configuration, bundle: bundle,
                                                  kernelCommandLine: manifest.kernelCommandLine, sockets: sockets,
                                                  hostIDEPort: hostIDEPort, consoleLog: console, backend: backend)
        DiagnosticsLog.record(.info, .runtime,
                              "Starting VM: \(configuration.cpuCount) CPUs, \(configuration.memoryMB) MB, \(backend.rawValue)")

        let exit = QEMUExit()
        Task.detached(priority: .userInitiated) {
            do {
                exit.record(.success(try await QEMULauncher.run(arguments: arguments, backend: backend)))
            } catch {
                exit.record(.failure(error as? QEMULauncher.LaunchError ?? .loadFailed(error.localizedDescription)))
            }
        }
        var monitor: QMPClient?
        do {
            // QEMU creates both sockets during initialization, long before the guest has booted.
            let monitorClient = QMPClient(transport: try await connect(sockets.monitor, unless: exit))
            monitor = monitorClient
            try await monitorClient.connect()
            // Resets must restart the guest; QEMU's -no-reboot would turn them into a power-off.
            try await monitorClient.execute("set-action", arguments: ["reboot": "reset"])
            let agent = GuestAgentClient(transport: try await connect(sockets.agent, unless: exit))
            await agent.start()
            return Instance(agent: agent, monitor: monitorClient, hostIDEPort: hostIDEPort, sockets: sockets, exit: exit,
                            image: configuration.image, diskNode: QEMUCommandLine.initialDiskNode, nodeSerial: 0)
        } catch {
            _ = try? await monitor?.execute("quit")
            _ = await exit.wait(timeout: .seconds(30))
            sockets.remove()
            DiagnosticsLog.record(.error, .runtime, "VM start failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Swaps in the environment's disk and boots the parked machine again. Memory and CPUs stay as
    /// configured by the first start of the session.
    private func attach(_ configuration: MachineConfiguration, to instance: inout Instance) async throws {
        instance.nodeSerial += 1
        let node = "sys\(instance.nodeSerial)"
        try await instance.monitor.execute("blockdev-add", json: QEMUCommandLine.diskNode(node, overlay: configuration.overlay))
        try await replaceDisk(of: &instance, with: node)
        try await instance.monitor.execute("system_reset")
        guard await waitForStatus(leaving: "shutdown", on: instance, timeout: .seconds(10)) else {
            throw QEMULauncher.LaunchError.restartRequired
        }
        try await instance.monitor.execute("cont")
        DiagnosticsLog.record(.info, .runtime, "Restarting VM with another environment")
    }

    /// Points the virtio device at `node` and frees the previous node and its file.
    private func replaceDisk(of instance: inout Instance, with node: String) async throws {
        try await instance.monitor.execute("qom-set", arguments: ["path": Self.devicePath, "property": "drive", "value": node])
        _ = try? await instance.monitor.execute("blockdev-del", arguments: ["node-name": instance.diskNode])
        instance.diskNode = node
    }

    private func waitForStatus(_ status: String, on instance: Instance, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? await instance.monitor.status()) == status { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func waitForStatus(leaving status: String, on instance: Instance, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let current = try? await instance.monitor.status(), current != status { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Makes the project's files available at `/workspace`, served by the app over 9P with the
    /// project's own folder as the root. Linux never sees anything else of the app: no other
    /// project, no app data. (QEMU's own shares can't change while the warm VM runs, so they
    /// could only offer all projects at once.)
    private func mount(_ source: WorkspaceSource, agent: GuestAgentClient) async throws {
        stopFolderServer()
        let root: URL
        let files: WorkspaceFiles?
        switch source {
        case .workingCopy(let folder):
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            root = folder
            files = nil
        case .folder(let binding):
            let access = try WorkspaceFiles(binding)
            root = access.url
            files = access
        }
        let server = NinePServer(root: root, token: SessionToken.generate())
        let port = try server.start()
        folderServer = (server, files)
        try await agent.send(.mountFolder(port: port, token: server.token))
    }

    private func stopFolderServer() {
        folderServer?.server.stop()
        folderServer = nil
    }

    /// Opens the agent session once the guest has booted. Linux discards serial data that arrives
    /// before the agent has opened its port, so the greeting is repeated until it is answered.
    private func greet(_ agent: GuestAgentClient, token: String, unless exit: QEMUExit, console: URL) async throws {
        let deadline = ContinuousClock.now + QEMUEmulatorAdapter.bootTimeout
        while true {
            do {
                _ = try await agent.hello(sessionToken: token, timeout: .seconds(5))
                return
            } catch GuestAgentClient.AgentError.timeout(_) where ContinuousClock.now < deadline {
                if case .success(let status)? = exit.result { throw QEMULauncher.LaunchError.exited(status) }
                if case .failure(let error)? = exit.result { throw error }
                if let reason = BootFailure.detect(in: console) {
                    DiagnosticsLog.record(.error, .runtime, "Guest boot failed: \(reason)")
                    throw QEMULauncher.LaunchError.guestBootFailed
                }
            }
        }
    }

    /// Connects to a QEMU socket, failing fast with QEMU's status if it exits during startup.
    private func connect(_ socket: URL, unless exit: QEMUExit) async throws -> UnixSocketTransport {
        do {
            return try await UnixSocketTransport.connect(path: socket.path(percentEncoded: false), timeout: .seconds(60)) {
                exit.result == nil
            }
        } catch {
            switch exit.result {
            case .success(let status)?: throw QEMULauncher.LaunchError.exited(status)
            case .failure(let launchError)?: throw launchError
            case nil: throw error
            }
        }
    }
}
