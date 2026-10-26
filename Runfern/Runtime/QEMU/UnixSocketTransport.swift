import Darwin
import Foundation

/// Byte channel over a Unix domain socket that QEMU serves for a character device, used for the
/// virtio-serial port of the GuestAgent and for the QMP monitor.
nonisolated final class UnixSocketTransport: AgentTransport, @unchecked Sendable {
    enum SocketError: LocalizedError {
        case pathTooLong
        case system(String, Int32)

        var errorDescription: String? {
            switch self {
            case .pathTooLong: "Socket path too long"
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    /// Stays open until deinit, so its number can never be reused while a write is pending.
    private let fd: Int32
    private let writer = DispatchQueue(label: "nrw.cyber.runfern.socket.write")

    /// Connects, retrying while the server has not created the socket yet and `shouldRetry` holds.
    static func connect(path: String, timeout: Duration,
                        shouldRetry: @Sendable () -> Bool = { true }) async throws -> UnixSocketTransport {
        let deadline = ContinuousClock.now + timeout
        while true {
            do {
                return try UnixSocketTransport(path: path)
            } catch SocketError.system(_, let code)
                        where (code == ENOENT || code == ECONNREFUSED) && ContinuousClock.now < deadline && shouldRetry() {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    init(path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.system("connect", code)
        }

        self.fd = fd
        (incoming, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let thread = Thread { [self] in readLoop() }
        thread.name = "nrw.cyber.runfern.socket.read"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            writer.async { [self] in
                completion.resume(with: Result { try writeAll(data) })
            }
        }
    }

    /// Ends both directions; the reader finishes the incoming stream.
    func close() {
        _ = shutdown(fd, SHUT_RDWR)
    }

    deinit {
        Darwin.close(fd)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw GuestAgentClient.AgentError.disconnected
                }
                offset += written
            }
        }
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                continuation.yield(Data(buffer[0..<count]))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        continuation.finish()
    }
}
