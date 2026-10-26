import Foundation

/// Byte channel to the guest. The real VM uses a virtio-serial port; tests and the
/// simulated runtime use an in-memory pair. The agent protocol is independent of both.
nonisolated protocol AgentTransport: Sendable {
    var incoming: AsyncThrowingStream<Data, Error> { get }
    func send(_ data: Data) async throws
    func close()
}

/// Splits a byte stream into newline-terminated frames.
nonisolated struct LineFramer {
    private var buffer = Data()
    /// Upper bound for a single frame; protects against a misbehaving guest.
    static let maximumLineLength = 1 << 20

    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer = buffer[buffer.index(after: newline)...]
        }
        guard buffer.count <= Self.maximumLineLength else { throw GuestAgentClient.AgentError.frameTooLarge }
        return lines.map { Data($0) }
    }
}

/// Two connected in-memory endpoints: what one sends, the other receives.
nonisolated struct InMemoryAgentTransport: AgentTransport {
    let incoming: AsyncThrowingStream<Data, Error>
    private let own: AsyncThrowingStream<Data, Error>.Continuation
    private let peer: AsyncThrowingStream<Data, Error>.Continuation

    static func pair() -> (host: InMemoryAgentTransport, guest: InMemoryAgentTransport) {
        let (hostStream, hostContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let (guestStream, guestContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        return (InMemoryAgentTransport(incoming: hostStream, own: hostContinuation, peer: guestContinuation),
                InMemoryAgentTransport(incoming: guestStream, own: guestContinuation, peer: hostContinuation))
    }

    func send(_ data: Data) async throws {
        if case .terminated = peer.yield(data) { throw GuestAgentClient.AgentError.disconnected }
    }

    func close() {
        own.finish()
        peer.finish()
    }
}
