import CryptoKit
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

/// Pairing files: StikJIT reads only Remote Pairing (RPPairing) files, never lockdown records.
@Suite struct PairingFileTests {
    private let signingKey = Curve25519.Signing.PrivateKey()

    private func plist(_ record: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: record, format: format, options: 0)
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private var remotePairing: [String: Any] {
        ["public_key": signingKey.publicKey.rawRepresentation, "private_key": signingKey.rawRepresentation,
         "identifier": "8C6F0E2A-6A4B-3C1D-9E8F-0123456789AB", "alt_irk": Data(repeating: 3, count: 16)]
    }

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary])
    func remotePairingFilesAreAccepted(format: PropertyListSerialization.PropertyListFormat) throws {
        try PairingFile.validate(plist(remotePairing, format: format))
    }

    @Test func altIRKIsOptional() throws {
        var record = remotePairing
        record["alt_irk"] = nil
        try PairingFile.validate(plist(record))
    }

    /// iloader adds lockdown secrets to the same file; only the four keys StikJIT reads are kept.
    @Test func extraKeysAreDropped() throws {
        var record = remotePairing
        record["HostPrivateKey"] = Data([4, 5, 6])
        record["EscrowBag"] = Data([7, 8, 9])
        let reduced = try dictionary(PairingFile.normalized(plist(record, format: .binary)))
        #expect(Set(reduced.keys) == ["public_key", "private_key", "identifier", "alt_irk"])
        #expect(reduced["private_key"] as? Data == signingKey.rawRepresentation)
        #expect(reduced["identifier"] as? String == "8C6F0E2A-6A4B-3C1D-9E8F-0123456789AB")
    }

    @Test func altIRKOfTheWrongSizeIsDropped() throws {
        var record = remotePairing
        record["alt_irk"] = Data(repeating: 3, count: 8)
        let reduced = try dictionary(PairingFile.normalized(plist(record)))
        #expect(reduced["alt_irk"] == nil)
    }

    @Test func normalizedFilesAreXMLAndStayValid() throws {
        let reduced = try PairingFile.normalized(plist(remotePairing, format: .binary))
        #expect(reduced.starts(with: Data("<?xml".utf8)))
        try PairingFile.validate(reduced)
    }

    @Test func lockdownRecordsAreRecognizedAndRejected() throws {
        let lockdown: [String: Any] = ["HostID": "A1B2", "SystemBUID": "C3D4", "HostCertificate": Data([1, 2, 3]),
                                       "HostPrivateKey": Data([4, 5, 6]), "DeviceCertificate": Data([7, 8, 9])]
        #expect(throws: PairingFile.ImportError.lockdownRecord) { try PairingFile.validate(plist(lockdown)) }
    }

    @Test func pymobiledevice3RecordsAreRecognizedAndRejected() throws {
        let record: [String: Any] = ["public_key": signingKey.publicKey.rawRepresentation,
                                     "private_key": signingKey.rawRepresentation,
                                     "remote_unlock_host_key": "ABCD"]
        #expect(throws: PairingFile.ImportError.pymobiledevice3Record) { try PairingFile.validate(plist(record)) }
    }

    @Test(arguments: ["public_key", "private_key", "identifier"])
    func incompleteFilesAreRejected(missing key: String) throws {
        var record = remotePairing
        record[key] = nil
        #expect(throws: PairingFile.ImportError.invalid) { try PairingFile.validate(plist(record)) }
    }

    @Test func keysOfTheWrongSizeAreRejected() throws {
        var record = remotePairing
        record["private_key"] = Data(repeating: 2, count: 64)
        #expect(throws: PairingFile.ImportError.invalid) { try PairingFile.validate(plist(record)) }
    }

    @Test func keysThatDoNotBelongTogetherAreRejected() throws {
        var record = remotePairing
        record["public_key"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        #expect(throws: PairingFile.ImportError.mismatchedKeys) { try PairingFile.validate(plist(record)) }
    }

    @Test func otherFilesAreRejected() {
        #expect(throws: PairingFile.ImportError.invalid) { try PairingFile.validate(Data("not a property list".utf8)) }
        #expect(throws: PairingFile.ImportError.invalid) { try PairingFile.validate(Data()) }
    }
}

/// The helper only acts on requests that carry their own one-time token.
@Suite struct JITProtocolTests {
    @Test func tokensMatchOnlyTheSameLongToken() {
        let token = String(repeating: "a", count: 43)
        #expect(JITProtocol.tokensMatch(stored: Data(token.utf8), given: token))
        #expect(!JITProtocol.tokensMatch(stored: Data(token.utf8), given: String(repeating: "b", count: 43)))
        #expect(!JITProtocol.tokensMatch(stored: Data(token.utf8), given: token + "a"))
        #expect(!JITProtocol.tokensMatch(stored: Data("short".utf8), given: "short"))
    }

    @Test func everyRequestHasItsOwnTokenFile() {
        let first = UUID()
        let second = UUID()
        #expect(JITProtocol.requestTokenFile(for: first) != JITProtocol.requestTokenFile(for: second))
        #expect(JITProtocol.requestTokenFile(for: first).hasSuffix(first.uuidString))
    }
}

/// A failed attempt is explained by how far the helper got.
@MainActor @Suite struct BuiltInJITExplanationTests {
    @Test func failuresAreExplainedByStage() {
        let response = JITHelperClient.Response(success: false, message: "boom", stage: JITProtocol.Stage.pairing)
        let text = BuiltInJIT.explanation(of: response)
        #expect(text != "boom")
        #expect(text.hasSuffix("(boom)"))
    }

    @Test func failuresWithoutStageKeepTheirMessage() {
        #expect(BuiltInJIT.explanation(of: .init(success: false, message: "boom")) == "boom")
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
