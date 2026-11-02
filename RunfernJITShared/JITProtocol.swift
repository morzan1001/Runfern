#if RUNFERN_JIT
import Foundation

/// What Runfern, its JIT helper extension, and its VPN extension agree on. Compiled into all three,
/// and only into builds with JIT (the extensions always are).
nonisolated enum JITProtocol {
    /// Shared container of Runfern and its JIT helper. Only these two can read it, which is how
    /// the helper knows a request comes from Runfern: Runfern puts a one-time token for every
    /// request there, and the helper only acts on a request that carries the same token.
    static let appGroup = "group.nrw.cyber.runfern"

    /// Name of the file in the shared container that holds the token of request `id`. Every
    /// request has its own file, so requests that overlap don't consume each other's token.
    static func requestTokenFile(for id: UUID) -> String {
        "jit-request-token-\(id.uuidString)"
    }

    /// Whether `given` equals the stored token, compared in constant time. Tokens are at least 32
    /// bytes long.
    static func tokensMatch(stored: Data, given: String) -> Bool {
        let expected = [UInt8](stored)
        let candidate = Array(given.utf8)
        guard expected.count >= 32, expected.count == candidate.count else { return false }
        return zip(expected, candidate).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Keys of the extension items that carry a request to the helper and its answer back.
    enum Key {
        static let requestID = "requestID"
        static let token = "token"
        static let operation = "operation"
        static let pid = "pid"
        static let pairing = "pairing"
        static let success = "success"
        static let message = "message"
        /// In a failed answer to `Operation.enable` or `Operation.prepare`: how far the helper got
        /// (`Stage`).
        static let stage = "stage"
    }

    /// Values of `Key.stage`, in the order the helper goes through them.
    enum Stage {
        /// Connecting to the developer services at `Tunnel.deviceAddress` through the VPN.
        static let reachability = "reachability"
        /// Pairing with the developer services and checking the Developer Disk Image.
        static let pairing = "pairing"
        /// Downloading the Developer Disk Image.
        static let diskImageDownload = "diskImageDownload"
        /// Mounting the Developer Disk Image.
        static let diskImageMount = "diskImageMount"
        /// Attaching the debugger and preparing QEMU's code region.
        static let debugger = "debugger"
    }

    /// Values of `Key.operation`.
    enum Operation {
        /// Attaches to Runfern and answers QEMU's code-region breakpoint until the script detaches.
        static let enable = "enable"
        /// Checks the way to the developer services (VPN, pairing file) and downloads and mounts
        /// the Developer Disk Image if needed, without attaching. Carries `Key.pairing`.
        static let prepare = "prepare"
        /// Removes the cached Developer Disk Image.
        static let resetDiskImage = "resetDiskImage"
    }

    /// The VPN's two ends. StikJIT reaches the iPad's developer services at `deviceAddress`, on
    /// the Remote Pairing port `remotePairingPort`, and the VPN turns every packet between the two
    /// addresses around, so the iPad talks to itself. Nothing else is routed through the VPN.
    enum Tunnel {
        static let interfaceAddress = "10.7.0.0"
        static let deviceAddress = "10.7.0.1"
        /// The iPad's Remote Pairing port. Fixed, as with StikJIT 1.9: StikJIT 2's Bonjour lookup
        /// takes the first service it finds, which need not be this iPad's.
        static let remotePairingPort: UInt16 = 49152

        private static let interface: [UInt8] = [10, 7, 0, 0]
        private static let device: [UInt8] = [10, 7, 0, 1]

        /// The IPv4 packet with source and destination swapped, or nil for anything but TCP or UDP
        /// from the interface address to the device address. Swapping both addresses keeps the
        /// IPv4 and the TCP/UDP checksums valid.
        static func turnedAround(_ packet: [UInt8]) -> [UInt8]? {
            // IPv4 header: version and length in byte 0, protocol at 9, source at 12, destination at 16.
            guard packet.count >= 20, packet[0] >> 4 == 4, Int(packet[0] & 0x0F) * 4 >= 20,
                  packet[9] == 6 || packet[9] == 17,
                  packet[12..<16].elementsEqual(interface), packet[16..<20].elementsEqual(device) else { return nil }
            var turned = packet
            turned.replaceSubrange(12..<16, with: packet[16..<20])
            turned.replaceSubrange(16..<20, with: packet[12..<16])
            return turned
        }
    }
}
#endif
