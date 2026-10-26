import Foundation

/// Runtime without a real VM until the feasibility proof (P1/G1). Every operation goes through the
/// real `GuestAgentClient` and agent protocol; only the guest itself is simulated.
nonisolated struct SimulatedEmulatorAdapter: EmulatorAdapter {
    private let machines = SimulatedMachines()

    var isSimulated: Bool { true }

    func createSystemDisk(image: URL, overlay: URL) async throws {
        try FileManager.default.createDirectory(at: overlay.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: overlay.path(percentEncoded: false)) {
            try Data().write(to: overlay)
        }
    }

    func installToolchains(_ toolchains: [ToolchainProfile], configuration: MachineConfiguration) async throws {
        try await machines.withAgent(for: configuration.environmentID) { agent in
            for toolchain in toolchains {
                try await agent.send(.installToolchain(toolchain), timeout: .seconds(600))
            }
        }
    }

    func removeSoftware(toolchains: [ToolchainProfile], extensions: [String], configuration: MachineConfiguration) async throws {
        try await machines.withAgent(for: configuration.environmentID) { agent in
            for toolchain in toolchains { try await agent.send(.removeToolchain(toolchain)) }
            if !extensions.isEmpty { try await agent.send(.removeExtensions(ids: extensions)) }
        }
    }

    func installExtensions(_ ids: [String], configuration: MachineConfiguration) async throws {
        try await machines.withAgent(for: configuration.environmentID) { agent in
            try await agent.send(.installExtensions(ids: ids), timeout: .seconds(600))
        }
    }

    func applyEditorSettings(_ settings: String, configuration: MachineConfiguration) async throws {
        try await machines.withAgent(for: configuration.environmentID) { agent in
            try await agent.send(.applyEditorSettings(settings: settings))
        }
    }

    func verify(configuration: MachineConfiguration) async throws {
        try await machines.withAgent(for: configuration.environmentID) { agent in
            try await agent.send(.healthCheck)
        }
    }

    func start(configuration: MachineConfiguration) async throws -> IDEEndpoint {
        let machine = try await machines.boot(configuration.environmentID)
        let reply = try await machine.agent.send(.startIDE(port: 8080), timeout: .seconds(120))
        let port = Int(reply.payload["port"] ?? "") ?? 8080
        return IDEEndpoint(url: URL(string: "http://127.0.0.1:\(port)")!, sessionToken: machine.sessionToken)
    }

    func forwardPort(_ guestPort: Int, environmentID: UUID) async throws -> Int {
        guard let agent = await machines.running(environmentID)?.agent else { throw GuestAgentClient.AgentError.disconnected }
        let reply = try await agent.send(.forwardPort(guestPort: guestPort))
        guard let hostPort = Int(reply.payload["hostPort"] ?? "") else { throw GuestAgentClient.AgentError.rejected("no host port") }
        return hostPort
    }

    func isResponsive(environmentID: UUID) async -> Bool {
        guard let agent = await machines.running(environmentID)?.agent else { return false }
        return (try? await agent.send(.healthCheck, timeout: .seconds(3))) != nil
    }

    func stop(environmentID: UUID) async throws {
        try await machines.shutDown(environmentID)
    }
}

/// Running simulated guests, keyed by environment. At most one is booted by the coordinator (ADR04);
/// provisioning may boot a transient one that is shut down again afterwards.
actor SimulatedMachines {
    struct Machine {
        let agent: GuestAgentClient
        let sessionToken: String
        let guestTask: Task<Void, Never>
    }

    private var machines: [UUID: Machine] = [:]

    func running(_ id: UUID) -> Machine? { machines[id] }

    func boot(_ id: UUID) async throws -> Machine {
        if let machine = machines[id] { return machine }
        let (host, guest) = InMemoryAgentTransport.pair()
        let simulatedGuest = SimulatedGuestAgent(transport: guest)
        let guestTask = Task { await simulatedGuest.run() }
        let agent = GuestAgentClient(transport: host)
        await agent.start()
        let token = SessionToken.generate()
        do {
            _ = try await agent.hello(sessionToken: token)
        } catch {
            guestTask.cancel()
            await agent.close()
            throw error
        }
        let machine = Machine(agent: agent, sessionToken: token, guestTask: guestTask)
        machines[id] = machine
        return machine
    }

    func shutDown(_ id: UUID) async throws {
        guard let machine = machines.removeValue(forKey: id) else { return }
        defer { machine.guestTask.cancel() }
        try await machine.agent.send(.shutdown, timeout: .seconds(60))
        await machine.agent.close()
    }

    /// Runs `body` against the guest, booting it only for the duration if it isn't running.
    func withAgent(for id: UUID, _ body: (GuestAgentClient) async throws -> Void) async throws {
        let wasRunning = machines[id] != nil
        let machine = try await boot(id)
        do {
            try await body(machine.agent)
        } catch {
            if !wasRunning { try? await shutDown(id) }
            throw error
        }
        if !wasRunning { try await shutDown(id) }
    }
}
