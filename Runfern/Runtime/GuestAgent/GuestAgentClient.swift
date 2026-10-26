import Foundation

/// Host side of the GuestAgent protocol (Plan 4.1). Correlates replies to requests,
/// enforces timeouts, and fails all pending requests when the guest disconnects.
actor GuestAgentClient {
    enum AgentError: LocalizedError, Equatable {
        case timeout(String)
        case disconnected
        case rejected(String)
        case protocolMismatch(Int)
        case frameTooLarge

        var errorDescription: String? {
            switch self {
            case .timeout(let command): String(localized: "The Linux environment did not respond in time (\(command)).")
            case .disconnected: String(localized: "The connection to the Linux environment was lost.")
            case .rejected(let reason): String(localized: "The Linux environment reported an error: \(reason)")
            case .protocolMismatch(let version): String(localized: "The Linux environment uses an incompatible agent (protocol \(version)).")
            case .frameTooLarge: String(localized: "The Linux environment sent an oversized message.")
            }
        }
    }

    nonisolated let events: AsyncStream<AgentEvent>
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private let transport: any AgentTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<AgentReply, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var isClosed = false

    init(transport: any AgentTransport) {
        self.transport = transport
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    func start() {
        guard readTask == nil else { return }
        readTask = Task { await readLoop() }
    }

    /// Sends a command and waits for its reply. A negative reply becomes `AgentError.rejected`.
    @discardableResult
    func send(_ command: AgentCommand, timeout: Duration = .seconds(30)) async throws -> AgentReply {
        guard !isClosed else { throw AgentError.disconnected }
        let id = nextID
        nextID += 1
        let line = try AgentCoding.encodeLine(AgentRequest(id: id, command: command))

        let reply = try await withThrowingTaskGroup(of: AgentReply.self) { group in
            group.addTask { try await self.awaitReply(id: id, sending: line) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AgentError.timeout(String(describing: command))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard reply.ok else { throw AgentError.rejected(reply.error ?? "unknown") }
        return reply
    }

    /// Opens the session: checks the protocol version and binds the session token.
    /// A real guest answers only once Linux has booted, so callers pass the boot time budget.
    func hello(sessionToken: String, timeout: Duration = .seconds(60)) async throws -> String {
        let reply = try await send(.hello(protocolVersion: agentProtocolVersion, sessionToken: sessionToken), timeout: timeout)
        let version = Int(reply.payload["protocolVersion"] ?? "") ?? -1
        guard version == agentProtocolVersion else { throw AgentError.protocolMismatch(version) }
        return reply.payload["agentVersion"] ?? "unknown"
    }

    func close() {
        transport.close()
        finish(with: AgentError.disconnected)
    }

    // MARK: Private

    private func awaitReply(id: Int, sending line: Data) async throws -> AgentReply {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A cancellation that arrived before registration would otherwise never resume.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                Task { await self.write(line, for: id) }
            }
        } onCancel: {
            Task { await self.resolve(id, with: .failure(CancellationError())) }
        }
    }

    private func write(_ line: Data, for id: Int) async {
        do {
            try await transport.send(line)
        } catch {
            resolve(id, with: .failure(error))
        }
    }

    private func resolve(_ id: Int, with result: Result<AgentReply, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func readLoop() async {
        var framer = LineFramer()
        do {
            for try await chunk in transport.incoming {
                for line in try framer.append(chunk) where !line.isEmpty {
                    handle(line)
                }
            }
            finish(with: AgentError.disconnected)
        } catch {
            finish(with: error)
        }
    }

    private func handle(_ line: Data) {
        // Malformed frames are reported but never crash the host.
        guard let frame = try? AgentCoding.decode(AgentFrame.self, from: line) else {
            eventContinuation.yield(.log(line: "Ignored malformed agent frame"))
            return
        }
        switch frame {
        case .reply(let reply): resolve(reply.id, with: .success(reply))
        case .event(let event): eventContinuation.yield(event)
        }
    }

    private func finish(with error: Error) {
        isClosed = true
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
        eventContinuation.finish()
    }
}
