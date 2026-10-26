import Foundation

/// The real runtime: an embedded QEMU without JIT running the catalog's Linux images (Plan 4.1).
///
/// The GuestAgent protocol is the same as with the simulated runtime; only the transport differs
/// (virtio-serial instead of memory). The editor is reached through a port forwarded to 127.0.0.1.
nonisolated struct QEMUEmulatorAdapter: EmulatorAdapter {
    /// Interpreted execution is slow; booting Linux may take minutes on first start.
    static let bootTimeout: Duration = .seconds(600)
    static let toolchainTimeout: Duration = .seconds(3600)

    private let machines = QEMUMachines()

    var isSimulated: Bool { false }

    func createSystemDisk(image: URL, overlay: URL) async throws {
        // An existing overlay holds installed tools; setup is resumed, never restarted from scratch.
        guard !FileManager.default.fileExists(atPath: overlay.path(percentEncoded: false)) else { return }
        try Qcow2Overlay.create(at: overlay, backingFile: ImageBundle(directory: image).disk)
    }

    func installToolchains(_ toolchains: [ToolchainProfile], configuration: MachineConfiguration) async throws {
        try await machines.withMachine(configuration) { machine in
            for toolchain in toolchains {
                // A canceled caller stops waiting, but the guest finishes the installation; the agent
                // serializes installs, so a run started on resume waits for it.
                _ = try await awaitDetached(Task {
                    try await machine.agent.send(.installToolchain(toolchain), timeout: Self.toolchainTimeout)
                })
            }
        }
    }

    func removeSoftware(toolchains: [ToolchainProfile], extensions: [String], configuration: MachineConfiguration) async throws {
        guard !toolchains.isEmpty || !extensions.isEmpty else { return }
        try await machines.withMachine(configuration) { machine in
            _ = try await awaitDetached(Task {
                for toolchain in toolchains {
                    try await machine.agent.send(.removeToolchain(toolchain), timeout: .seconds(600))
                }
                if !extensions.isEmpty {
                    try await machine.agent.send(.removeExtensions(ids: extensions), timeout: .seconds(600))
                }
            })
        }
    }

    func installExtensions(_ ids: [String], configuration: MachineConfiguration) async throws {
        guard !ids.isEmpty else { return }
        try await machines.withMachine(configuration) { machine in
            do {
                _ = try await awaitDetached(Task {
                    try await machine.agent.send(.installExtensions(ids: ids), timeout: Self.toolchainTimeout)
                })
            } catch GuestAgentClient.AgentError.rejected(let reason) where reason.hasPrefix("unknown command") {
                throw ExtensionError.unsupportedBase
            }
        }
    }

    func applyEditorSettings(_ settings: String, configuration: MachineConfiguration) async throws {
        try await machines.withMachine(configuration) { machine in
            do {
                try await machine.agent.send(.applyEditorSettings(settings: settings))
            } catch GuestAgentClient.AgentError.rejected(let reason) where reason.hasPrefix("unknown command") {
                throw ExtensionError.unsupportedBase
            }
        }
    }

    enum ExtensionError: LocalizedError {
        case unsupportedBase

        var errorDescription: String? {
            String(localized: "This Linux base does not support extensions and VS Code settings yet. Create a new project with the current base.")
        }
    }

    func verify(configuration: MachineConfiguration) async throws {
        try await machines.withMachine(configuration) { machine in
            try await machine.agent.send(.healthCheck, timeout: .seconds(120))
        }
    }

    func start(configuration: MachineConfiguration) async throws -> IDEEndpoint {
        let machine = try await machines.boot(configuration)
        try await machine.agent.send(.startIDE(port: QEMUCommandLine.guestIDEPort), timeout: .seconds(300))
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = machine.hostIDEPort
        components.path = "/"
        // The editor only accepts connections that present the session's token (Plan 4.8).
        components.queryItems = [URLQueryItem(name: "tkn", value: machine.sessionToken),
                                 URLQueryItem(name: "folder", value: "/workspace")]
        return IDEEndpoint(url: components.url!, sessionToken: machine.sessionToken)
    }

    func forwardPort(_ guestPort: Int, environmentID: UUID) async throws -> Int {
        try await machines.forward(guestPort, environmentID: environmentID)
    }

    func isResponsive(environmentID: UUID) async -> Bool {
        guard let machine = await machines.running(environmentID) else { return false }
        return (try? await machine.agent.send(.healthCheck, timeout: .seconds(5))) != nil
    }

    func stop(environmentID: UUID) async throws {
        try await machines.shutDown(environmentID)
    }
}
