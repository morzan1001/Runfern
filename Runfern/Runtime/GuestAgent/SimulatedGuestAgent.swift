import Foundation

/// Guest side of the agent protocol without a real VM. It behaves like the planned
/// in-guest agent so the host code path is exercised end to end until QEMU is integrated.
actor SimulatedGuestAgent {
    private let transport: any AgentTransport
    private let latency: Duration
    private var sessionToken: String?
    private var installed: [String: Int] = [:]
    private var idePort: Int?

    init(transport: any AgentTransport, latency: Duration = .milliseconds(120)) {
        self.transport = transport
        self.latency = latency
    }

    /// Serves requests until the host disconnects or a shutdown completes.
    func run() async {
        var framer = LineFramer()
        do {
            for try await chunk in transport.incoming {
                for line in try framer.append(chunk) where !line.isEmpty {
                    guard let request = try? AgentCoding.decode(AgentRequest.self, from: line) else { continue }
                    let finished = try await handle(request)
                    if finished { return }
                }
            }
        } catch {
            transport.close()
        }
    }

    private func handle(_ request: AgentRequest) async throws -> Bool {
        try await Task.sleep(for: latency)
        switch request.command {
        case let .hello(version, token):
            guard version == agentProtocolVersion else {
                try await reply(request, ok: false, error: "unsupported protocol \(version)")
                return false
            }
            sessionToken = token
            try await reply(request, payload: ["protocolVersion": "\(agentProtocolVersion)", "agentVersion": "simulated-1"])
            try await emit(.ready(agentVersion: "simulated-1"))

        case .installToolchain(let id, let revision, _, _, _) where sessionToken != nil:
            for step in 1...3 {
                try await emit(.progress(step: id, fraction: Double(step) / 3))
                try await Task.sleep(for: latency)
            }
            installed[id] = revision
            try await reply(request, payload: ["installed": id])

        case .installExtensions(let files) where sessionToken != nil:
            try await reply(request, payload: ["installed": files.joined(separator: ",")])

        case .removeToolchain(let id, _, _) where sessionToken != nil:
            installed[id] = nil
            try await reply(request)

        case .removeExtensions where sessionToken != nil:
            try await reply(request)

        case .mountFolder where sessionToken != nil:
            try await reply(request)

        case .applyEditorSettings where sessionToken != nil:
            try await reply(request)

        case .healthCheck where sessionToken != nil:
            try await reply(request, payload: ["linux": "ok", "agent": "ok", "toolchains": installed.keys.sorted().joined(separator: ",")])

        case .startIDE(let port) where sessionToken != nil:
            idePort = port
            try await reply(request, payload: ["port": "\(port)"])

        case .forwardPort(let guestPort) where sessionToken != nil:
            // The simulated guest runs no server; the mapping itself follows the real protocol.
            try await reply(request, payload: ["hostPort": "\(20_000 + guestPort % 10_000)"])

        case .shutdown:
            try await reply(request)
            try await emit(.shutdownComplete)
            transport.close()
            return true

        default:
            try await reply(request, ok: false, error: "session not opened")
        }
        return false
    }

    private func reply(_ request: AgentRequest, ok: Bool = true, error: String? = nil, payload: [String: String] = [:]) async throws {
        try await transport.send(AgentCoding.encodeLine(AgentFrame.reply(AgentReply(id: request.id, ok: ok, error: error, payload: payload))))
    }

    private func emit(_ event: AgentEvent) async throws {
        try await transport.send(AgentCoding.encodeLine(AgentFrame.event(event)))
    }
}
