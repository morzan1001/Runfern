import Foundation
import Testing
@testable import Runfern

#if RUNFERN_JIT
/// The VPN's packet filter: only TCP and UDP between its two addresses is turned around.
@Suite struct LoopbackTunnelFilterTests {
    /// A minimal IPv4 header with the given protocol, source, and destination.
    private func packet(protocol number: UInt8, from source: [UInt8], to destination: [UInt8], version: UInt8 = 4) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes[0] = version << 4 | 5
        bytes[9] = number
        bytes.replaceSubrange(12..<16, with: source)
        bytes.replaceSubrange(16..<20, with: destination)
        return bytes
    }

    private let interface: [UInt8] = [10, 7, 0, 0]
    private let device: [UInt8] = [10, 7, 0, 1]

    @Test(arguments: [UInt8(6), UInt8(17)])
    func tcpAndUDPBetweenTheTunnelAddressesAreTurnedAround(protocol number: UInt8) throws {
        let original = packet(protocol: number, from: interface, to: device)
        let turned = try #require(JITProtocol.Tunnel.turnedAround(original))
        #expect(Array(turned[12..<16]) == device)
        #expect(Array(turned[16..<20]) == interface)
        #expect(turned[20...] == original[20...])
    }

    @Test func otherAddressesAreDropped() {
        #expect(JITProtocol.Tunnel.turnedAround(packet(protocol: 6, from: interface, to: [1, 1, 1, 1])) == nil)
        #expect(JITProtocol.Tunnel.turnedAround(packet(protocol: 6, from: [192, 168, 0, 2], to: device)) == nil)
        #expect(JITProtocol.Tunnel.turnedAround(packet(protocol: 6, from: device, to: interface)) == nil)
    }

    @Test func otherProtocolsAndMalformedPacketsAreDropped() {
        #expect(JITProtocol.Tunnel.turnedAround(packet(protocol: 1, from: interface, to: device)) == nil)
        #expect(JITProtocol.Tunnel.turnedAround(packet(protocol: 6, from: interface, to: device, version: 6)) == nil)
        #expect(JITProtocol.Tunnel.turnedAround(Array(packet(protocol: 6, from: interface, to: device).prefix(19))) == nil)
    }
}

/// The request Runfern sends to StikDebug (StikJIT INTEGRATION.md).
@Suite struct StikDebugTests {
    @Test func requestNamesProcessAndTheFixedScript() throws {
        let url = try #require(StikDebug.requestURL(bundleID: "nrw.cyber.runfern", pid: 4242))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "stikdebug")
        #expect(components.host == "enable-jit")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["bundle-id"] == "nrw.cyber.runfern")
        #expect(items["pid"] == "4242")
        #expect(items["script-name"] == "legacy.js")
    }
}
#endif
