#if RUNFERN_JIT && canImport(IDevice)
import Darwin
import Foundation
import IDevice

/// Creates this iPad's Remote Pairing file without a computer, with idevice's pairable host (MIT,
/// `Vendor/JIT/IDevice.xcframework`).
///
/// Since iPadOS 27 the iPad can start a pairing itself ("device-initiated pairing"): a host
/// advertises `_remotepairing-pairable-host._tcp` on the local network, and Settings › Privacy &
/// Security › Developer Mode offers “Pair with <name>”. The iPad then connects to the host, the
/// host shows a 6-digit code, and the person types it on the iPad. Here Runfern is that host for
/// its own iPad: it listens on a TCP port, advertises it with Bonjour, accepts only a connection
/// from this iPad itself, and lets idevice run the pairing (`pairable_host_accept_fd`). The result
/// is exactly the RPPairing file StikJIT reads.
///
/// All blocking work runs on one dedicated thread: `pairable_host_accept_fd` blocks its thread
/// until the pairing ends, and calls the code callback on that same thread.
nonisolated final class PairingHost: @unchecked Sendable {
    static let serviceType = "_remotepairing-pairable-host._tcp."

    enum HostError: LocalizedError {
        case setup(String)
        case timedOut
        case cancelled
        case pairing(String)

        var errorDescription: String? {
            switch self {
            case .setup(let reason): String(localized: "Runfern could not prepare the pairing: \(reason)")
            case .timedOut: String(localized: "The pairing took too long. Try again.")
            case .cancelled: String(localized: "The pairing was cancelled.")
            case .pairing(let reason): String(localized: "The pairing failed: \(reason). If you typed the code, check it and try again.")
            }
        }
    }

    /// What happens during `pair`, reported on the pairing thread.
    enum Event: Sendable {
        /// This iPad has connected; the code follows.
        case connected
        /// The code to type on the iPad.
        case code(String)
    }

    /// A finished pairing.
    struct Pairing: Sendable {
        /// The RPPairing file (XML property list).
        var file: Data
        /// The iPad's name, as it introduced itself.
        var deviceName: String?
    }

    /// The Bonjour instance name, which is also the pairing file's identifier.
    let serviceName: String
    /// The TXT record to publish with the service.
    let txtRecord: [String: String]
    /// The TCP port the host listens on.
    let port: UInt16

    private let handle: OpaquePointer
    private let listener: Int32
    private let cancelPipe: (read: Int32, write: Int32)
    private let lock = NSLock()
    private var connection: Int32 = -1
    private var stopReason: HostError?
    private var isClosed = false
    private var onEvent: (@Sendable (Event) -> Void)?

    /// Generates a fresh host identity named `name` (shown on the iPad) and starts listening.
    init(name: String) throws {
        var handle: OpaquePointer?
        var serviceID: UnsafeMutablePointer<CChar>?
        var txt: UnsafeMutablePointer<UInt8>?
        var txtLength: UInt = 0
        let error = name.withCString { name in
            pairable_host_prepare(name, nil, false, &handle, &serviceID, &txt, &txtLength, nil)
        }
        if let error { throw HostError.setup(Self.message(of: error)) }
        guard let handle, let serviceID, let txt else { throw HostError.setup("no host identity") }
        let serviceName = String(cString: serviceID)
        idevice_string_free(serviceID)
        let txtData = Data(bytes: txt, count: Int(txtLength))
        idevice_data_free(txt, txtLength)
        // idevice hands the TXT entries over as a property list of strings.
        guard let txtRecord = try? PropertyListSerialization.propertyList(from: txtData, format: nil) as? [String: String] else {
            pairable_host_free(handle)
            throw HostError.setup("unreadable TXT record")
        }

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            pairable_host_free(handle)
            throw HostError.setup(Self.lastSystemError())
        }
        let listening: (fd: Int32, port: UInt16)
        do {
            listening = try Self.listen()
        } catch {
            Darwin.close(pipeFDs[0])
            Darwin.close(pipeFDs[1])
            pairable_host_free(handle)
            throw error
        }

        self.handle = handle
        self.serviceName = serviceName
        self.txtRecord = txtRecord
        listener = listening.fd
        port = listening.port
        cancelPipe = (pipeFDs[0], pipeFDs[1])
    }

    deinit {
        closeAll()
        pairable_host_free(handle)
    }

    /// Waits for this iPad to connect and runs the pairing. Gives up after `timeout`, or when the
    /// calling task is cancelled.
    func pair(timeout: Duration, onEvent: @escaping @Sendable (Event) -> Void) async throws -> Pairing {
        lock.withLock { self.onEvent = onEvent }
        let seconds = Double(timeout.components.seconds)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stop(.timedOut) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Pairing, Error>) in
                let thread = Thread { [self] in
                    continuation.resume(with: Result { try self.acceptAndPair() })
                }
                thread.name = "nrw.cyber.runfern.pairing"
                thread.start()
            }
        } onCancel: {
            self.stop(.cancelled)
        }
    }

    /// Ends a running `pair`: wakes the wait for a connection and closes a connection in progress.
    func stop(_ reason: HostError = .cancelled) {
        lock.withLock {
            guard stopReason == nil, !isClosed else { return }
            stopReason = reason
            var byte: UInt8 = 1
            _ = Darwin.write(cancelPipe.write, &byte, 1)
            if connection >= 0 { _ = Darwin.shutdown(connection, SHUT_RDWR) }
        }
    }

    // MARK: - Pairing thread

    private func acceptAndPair() throws -> Pairing {
        defer { closeAll() }
        let connection = try acceptLocalConnection()
        report(.connected)
        var peer: UnsafeMutablePointer<RpPairingPeerDeviceC>?
        var file: OpaquePointer?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = pairable_host_accept_fd(handle, connection, { code, context in
            guard let code, let context else { return }
            // `code` is valid only during this call.
            Unmanaged<PairingHost>.fromOpaque(context).takeUnretainedValue().report(.code(String(cString: code)))
        }, context, &peer, &file)
        defer {
            if let peer { rppairing_peer_device_free(peer) }
            if let file { rp_pairing_file_free(file) }
        }
        if let error {
            let reason = Self.message(of: error)
            throw lock.withLock { stopReason } ?? HostError.pairing(reason)
        }
        guard let file else { throw HostError.pairing("no pairing file") }

        var bytes: UnsafeMutablePointer<UInt8>?
        var count: UInt = 0
        if let error = rp_pairing_file_to_bytes(file, &bytes, &count) { throw HostError.pairing(Self.message(of: error)) }
        guard let bytes else { throw HostError.pairing("empty pairing file") }
        let data = Data(bytes: bytes, count: Int(count))
        idevice_data_free(bytes, count)
        let deviceName = peer.flatMap { $0.pointee.name }.map { String(cString: $0) }
        return Pairing(file: data, deviceName: deviceName)
    }

    /// The first connection that comes from this iPad itself. Connections from other devices on
    /// the network are closed right away.
    private func acceptLocalConnection() throws -> Int32 {
        while true {
            var descriptors = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: cancelPipe.read, events: Int16(POLLIN), revents: 0)]
            let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
            if let reason = lock.withLock({ stopReason }) { throw reason }
            if ready < 0 {
                if errno == EINTR { continue }
                throw HostError.setup(Self.lastSystemError())
            }
            guard descriptors[0].revents & Int16(POLLIN) != 0 else { continue }
            let accepted = Darwin.accept(listener, nil, nil)
            guard accepted >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                throw HostError.setup(Self.lastSystemError())
            }
            guard Self.isFromThisDevice(accepted) else {
                Darwin.close(accepted)
                continue
            }
            // idevice writes with send(), which raises SIGPIPE on a closed socket unless the socket
            // says otherwise. The flag belongs to the socket, so idevice's dup() of it has it too.
            var noSigPipe: Int32 = 1
            _ = Darwin.setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let isStopped = lock.withLock {
                if stopReason == nil { connection = accepted }
                return stopReason != nil
            }
            if isStopped {
                Darwin.close(accepted)
                throw lock.withLock { stopReason } ?? HostError.cancelled
            }
            return accepted
        }
    }

    private func report(_ event: Event) {
        lock.withLock { onEvent }?(event)
    }

    private func closeAll() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            if connection >= 0 { Darwin.close(connection) }
            connection = -1
            Darwin.close(listener)
            Darwin.close(cancelPipe.read)
            Darwin.close(cancelPipe.write)
            onEvent = nil
        }
    }

    // MARK: - Sockets

    /// A TCP socket listening on all IPv4 addresses, on a port the system picks.
    private static func listen() throws -> (fd: Int32, port: UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostError.setup(lastSystemError()) }
        var on: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0, named == 0 else {
            let reason = lastSystemError()
            Darwin.close(fd)
            throw HostError.setup(reason)
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    /// Whether the connection `fd` comes from this iPad: its peer has the address it was made to,
    /// or a loopback address.
    static func isFromThisDevice(_ fd: Int32) -> Bool {
        guard let peer = address(of: fd, peer: true), let local = address(of: fd, peer: false) else { return false }
        return isLocal(peer: peer, local: local)
    }

    /// Whether a connection from `peer` to `local` (IPv4 addresses in host byte order) stays on
    /// this device.
    static func isLocal(peer: UInt32, local: UInt32) -> Bool {
        peer == local || peer >> 24 == 127
    }

    private static func address(of fd: Int32, peer: Bool) -> UInt32? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                peer ? Darwin.getpeername(fd, $0, &length) : Darwin.getsockname(fd, $0, &length)
            }
        }
        guard result == 0, address.sin_family == sa_family_t(AF_INET) else { return nil }
        return UInt32(bigEndian: address.sin_addr.s_addr)
    }

    private static func lastSystemError() -> String {
        String(cString: strerror(errno))
    }

    /// The error's message; frees the error.
    private static func message(of error: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        let message = error.pointee.message.map { String(cString: $0) } ?? "error \(error.pointee.code)"
        idevice_error_free(error)
        return message
    }
}
#endif
