#if RUNFERN_JIT
/// What Runfern, its JIT helper extension, and its VPN extension agree on. Compiled into all three,
/// and only into builds with JIT (the extensions always are).
nonisolated enum JITProtocol {
    /// Shared container of Runfern and its JIT helper. Only these two can read it, which is how
    /// the helper knows a request comes from Runfern: Runfern puts a one-time token for every
    /// request there, and the helper only acts on a request that carries the same token.
    static let appGroup = "group.nrw.cyber.runfern"
    static let requestTokenFile = "jit-request-token"

    /// Keys of the extension items that carry a request to the helper and its answer back.
    enum Key {
        static let token = "token"
        static let operation = "operation"
        static let pid = "pid"
        static let pairing = "pairing"
        static let success = "success"
        static let message = "message"
    }

    /// Values of `Key.operation`.
    enum Operation {
        /// Attaches to Runfern and answers QEMU's code-region breakpoint until the script detaches.
        static let enable = "enable"
        /// Removes the cached Developer Disk Image.
        static let resetDiskImage = "resetDiskImage"
    }

    /// The VPN's two ends. StikJIT reaches the iPad's developer services at `deviceAddress`
    /// (its default), and the VPN turns every packet between the two addresses around, so the
    /// iPad talks to itself. Nothing else is routed through the VPN.
    enum Tunnel {
        static let interfaceAddress = "10.7.0.0"
        static let deviceAddress = "10.7.0.1"

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
