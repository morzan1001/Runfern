import Darwin

/// Finds free TCP ports on 127.0.0.1 for forwarded guest services.
nonisolated enum LoopbackPort {
    /// Asks the system for an unused port. QEMU binds it shortly afterwards; a collision in between
    /// makes the forwarding fail visibly rather than reach another service.
    static func free() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketTransport.SocketError.system("socket", errno) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        guard bound else { throw UnixSocketTransport.SocketError.system("bind", errno) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
