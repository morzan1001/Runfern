import Foundation
import Testing
@testable import Runfern

/// Verifies the host side of the GuestAgent protocol (Plan 4.1, 4.8).
@Suite struct GuestAgentTests {
    private func connectedAgent(latency: Duration = .milliseconds(1)) async -> (GuestAgentClient, InMemoryAgentTransport) {
        let (host, guest) = InMemoryAgentTransport.pair()
        let simulated = SimulatedGuestAgent(transport: guest, latency: latency)
        Task { await simulated.run() }
        let client = GuestAgentClient(transport: host)
        await client.start()
        return (client, guest)
    }

    @Test func handshakeAndCommandsSucceed() async throws {
        let (client, _) = await connectedAgent()

        let version = try await client.hello(sessionToken: SessionToken.generate())
        try await client.send(.installToolchain(try #require(Catalog.toolchain(id: "python-3"))))
        let health = try await client.send(.healthCheck)
        let ide = try await client.send(.startIDE(port: 8123))

        #expect(version == "simulated-1")
        #expect(health.payload["toolchains"] == "python-3")
        #expect(ide.payload["port"] == "8123")
    }

    @Test func commandsBeforeHelloAreRejected() async throws {
        let (client, _) = await connectedAgent()

        await #expect(throws: GuestAgentClient.AgentError.rejected("session not opened")) {
            try await client.send(.healthCheck)
        }
    }

    @Test func silentGuestTimesOut() async throws {
        // The guest end stays open but never answers.
        let (host, guest) = InMemoryAgentTransport.pair()
        let client = GuestAgentClient(transport: host)
        await client.start()

        await #expect(throws: GuestAgentClient.AgentError.timeout(String(describing: AgentCommand.healthCheck))) {
            try await client.send(.healthCheck, timeout: .milliseconds(50))
        }
        withExtendedLifetime(guest) {}
    }

    @Test func disconnectFailsPendingRequests() async throws {
        let (host, guest) = InMemoryAgentTransport.pair()
        let client = GuestAgentClient(transport: host)
        await client.start()

        let pending = Task { try await client.send(.healthCheck, timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        guest.close()

        await #expect(throws: GuestAgentClient.AgentError.disconnected) { try await pending.value }
    }

    @Test func malformedFramesAreIgnored() async throws {
        let (host, guest) = InMemoryAgentTransport.pair()
        let client = GuestAgentClient(transport: host)
        await client.start()

        try await guest.send(Data("not json\n".utf8))
        try await guest.send(AgentCoding.encodeLine(AgentFrame.event(.ready(agentVersion: "x"))))

        var iterator = client.events.makeAsyncIterator()
        #expect(await iterator.next() == .log(line: "Ignored malformed agent frame"))
        #expect(await iterator.next() == .ready(agentVersion: "x"))
    }

    @Test func lineFramerJoinsSplitChunks() throws {
        var framer = LineFramer()

        #expect(try framer.append(Data("{\"a\":".utf8)).isEmpty)
        let lines = try framer.append(Data("1}\n{\"b\":2}\n".utf8))

        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}"])
    }

    @Test func sessionTokensAreRandomAndURLSafe() {
        let tokens = (0..<20).map { _ in SessionToken.generate() }

        #expect(Set(tokens).count == 20)
        #expect(tokens.allSatisfy { $0.count == 43 && !$0.contains("+") && !$0.contains("/") && !$0.contains("=") })
    }

    @Test func simulatedAdapterRunsFullLifecycle() async throws {
        let adapter = SimulatedEmulatorAdapter()
        let id = UUID()
        let configuration = MachineConfiguration(environmentID: id, image: URL(filePath: "/dev/null"),
                                                 overlay: URL(filePath: "/dev/null"), workspace: .workingCopy(URL(filePath: "/dev/null")))

        try await adapter.installToolchains(Catalog.toolchains, configuration: configuration)
        try await adapter.verify(configuration: configuration)
        let endpoint = try await adapter.start(configuration: configuration)
        let responsive = await adapter.isResponsive(environmentID: id)
        try await adapter.stop(environmentID: id)
        let afterStop = await adapter.isResponsive(environmentID: id)

        #expect(endpoint.url.host() == "127.0.0.1")
        #expect(endpoint.sessionToken.count == 43)
        #expect(responsive)
        #expect(!afterStop)
    }

    /// The Linux agent writes plain JSON; these literals are exactly what runfern-agent.py sends.
    @Test func decodesFramesOfTheLinuxAgent() throws {
        let reply = try AgentCoding.decode(AgentFrame.self, from: Data(#"{"reply":{"id":3,"ok":false,"error":"no recipe","payload":{}}}"#.utf8))
        #expect(reply == .reply(AgentReply(id: 3, ok: false, error: "no recipe")))

        let ready = try AgentCoding.decode(AgentFrame.self, from: Data(#"{"event":{"ready":{"agentVersion":"1.0.0"}}}"#.utf8))
        #expect(ready == .event(.ready(agentVersion: "1.0.0")))

        let done = try AgentCoding.decode(AgentFrame.self, from: Data(#"{"event":{"shutdownComplete":{}}}"#.utf8))
        #expect(done == .event(.shutdownComplete))

        let request = String(decoding: try AgentCoding.encodeLine(AgentRequest(id: 1, command: .healthCheck)), as: UTF8.self)
        #expect(request.contains(#""command":{"healthCheck":{}}"#))
    }
}
