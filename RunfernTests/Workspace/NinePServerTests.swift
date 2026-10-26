import Darwin
import Foundation
import Testing
@testable import Runfern

/// Talks 9P2000.L to the folder server the way Linux' v9fs client does.
@Suite struct NinePServerTests {
    let root: URL
    let server: NinePServer

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ninep-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appending(path: "hello.txt"))
        server = NinePServer(root: root, token: "token-0123456789abcdef")
        try server.start()
    }

    @Test func rejectsWrongToken() throws {
        let client = try Client(port: server.port)
        try client.version()
        let reply = try client.attach(fid: 0, token: "wrong")
        #expect(reply.type == NinePType.rlerror)
        #expect(reply.errno == UInt32(EACCES))
    }

    @Test func readsAndWritesFiles() throws {
        let client = try Client(port: server.port)
        try client.version()
        #expect(try client.attach(fid: 0, token: server.token).type == NinePType.tattach + 1)

        // Reads an existing file.
        #expect(try client.walk(fid: 0, newFid: 1, names: ["hello.txt"]).type == NinePType.twalk + 1)
        #expect(try client.open(fid: 1).type == NinePType.tlopen + 1)
        #expect(try client.read(fid: 1, count: 100) == Data("hello".utf8))

        // Creates a new file in a subfolder.
        _ = try client.walk(fid: 0, newFid: 2, names: ["sub"])
        #expect(try client.create(fid: 2, name: "new.txt").type == NinePType.tlcreate + 1)
        #expect(try client.write(fid: 2, data: Data("from linux".utf8)).type == NinePType.twrite + 1)
        #expect(try String(contentsOf: root.appending(path: "sub/new.txt"), encoding: .utf8) == "from linux")

        // Names that would leave the directory are refused.
        _ = try client.walk(fid: 0, newFid: 3, names: [])
        #expect(try client.create(fid: 3, name: "../escape.txt").type == NinePType.rlerror)
    }

    @Test func walkStaysInsideTheFolder() throws {
        let client = try Client(port: server.port)
        try client.version()
        _ = try client.attach(fid: 0, token: server.token)
        // ".." at the root stays at the root, so the walk ends where it started.
        #expect(try client.walk(fid: 0, newFid: 1, names: ["..", "..", "hello.txt"]).type == NinePType.twalk + 1)
        #expect(try client.open(fid: 1).type == NinePType.tlopen + 1)
        #expect(try client.read(fid: 1, count: 100) == Data("hello".utf8))
    }

    @Test func requestsBeforeAttachAreRefused() throws {
        let client = try Client(port: server.port)
        try client.version()
        let reply = try client.walk(fid: 0, newFid: 1, names: ["hello.txt"])
        #expect(reply.errno == UInt32(EACCES))
    }

    @Test func wrongTokenEndsTheConnection() throws {
        let client = try Client(port: server.port)
        try client.version()
        #expect(try client.attach(fid: 0, token: "wrong").errno == UInt32(EACCES))
        #expect(throws: (any Error).self) { try client.attach(fid: 0, token: server.token) }
    }

    /// The guest may plant links to anywhere; the server must never follow them.
    @Test func linksAreNeverFollowed() throws {
        let outside = FileManager.default.temporaryDirectory.appending(path: "ninep-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appending(path: "secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "folder-link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "file-link"),
                                                   withDestinationURL: outside.appending(path: "secret.txt"))

        let client = try Client(port: server.port)
        try client.version()
        _ = try client.attach(fid: 0, token: server.token)

        // Walking through a link to a folder outside fails.
        #expect(try client.walk(fid: 0, newFid: 1, names: ["folder-link", "secret.txt"]).type != NinePType.twalk + 1
                || client.lastWalkCount < 2)
        // A link to a file outside can be walked to (it is the link itself) but not opened.
        #expect(try client.walk(fid: 0, newFid: 2, names: ["file-link"]).type == NinePType.twalk + 1)
        #expect(try client.open(fid: 2).type == NinePType.rlerror)
        // Nothing can be created through a link either.
        #expect(try client.walk(fid: 0, newFid: 3, names: ["folder-link"]).type == NinePType.twalk + 1)
        #expect(try client.create(fid: 3, name: "planted.txt").type == NinePType.rlerror)
        // A link the guest creates itself, pointing at the root of the iPad's file system, leads nowhere.
        #expect(try client.symlink(fid: 0, name: "planted-link", target: "/").type == NinePType.tsymlink + 1)
        #expect(try client.walk(fid: 0, newFid: 4, names: ["planted-link", "private"]).type != NinePType.twalk + 1
                || client.lastWalkCount < 2)

        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "planted.txt").path(percentEncoded: false)))
        #expect(try String(contentsOf: outside.appending(path: "secret.txt"), encoding: .utf8) == "secret")
    }
}

/// A minimal blocking 9P client for the tests.
private final class Client {
    struct Reply {
        let type: UInt8
        var body: NinePReader
        var errno: UInt32? {
            var reader = body
            return type == NinePType.rlerror ? try? reader.u32() : nil
        }
    }

    private let socket: Int32

    init(port: Int) throws {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw NinePError.current }
    }

    deinit { close(socket) }

    func version() throws {
        var w = NinePWriter()
        w.u32(65536)
        w.string("9P2000.L")
        _ = try request(NinePType.tversion, w)
    }

    func attach(fid: UInt32, token: String) throws -> Reply {
        var w = NinePWriter()
        w.u32(fid); w.u32(UInt32.max); w.string("runfern"); w.string(token); w.u32(501)
        return try request(NinePType.tattach, w)
    }

    /// Number of names the last successful walk got through.
    private(set) var lastWalkCount = 0

    func walk(fid: UInt32, newFid: UInt32, names: [String]) throws -> Reply {
        var w = NinePWriter()
        w.u32(fid); w.u32(newFid); w.u16(UInt16(names.count))
        names.forEach { w.string($0) }
        let reply = try request(NinePType.twalk, w)
        var body = reply.body
        lastWalkCount = reply.type == NinePType.twalk + 1 ? Int((try? body.u16()) ?? 0) : 0
        return reply
    }

    func symlink(fid: UInt32, name: String, target: String) throws -> Reply {
        var w = NinePWriter()
        w.u32(fid); w.string(name); w.string(target); w.u32(1000)
        return try request(NinePType.tsymlink, w)
    }

    func open(fid: UInt32) throws -> Reply {
        var w = NinePWriter()
        w.u32(fid); w.u32(0)
        return try request(NinePType.tlopen, w)
    }

    func create(fid: UInt32, name: String) throws -> Reply {
        var w = NinePWriter()
        w.u32(fid); w.string(name); w.u32(0o2); w.u32(0o644); w.u32(1000)
        return try request(NinePType.tlcreate, w)
    }

    func read(fid: UInt32, count: UInt32) throws -> Data {
        var w = NinePWriter()
        w.u32(fid); w.u64(0); w.u32(count)
        var reply = try request(NinePType.tread, w)
        return try reply.body.bytes(Int(try reply.body.u32()))
    }

    func write(fid: UInt32, data: Data) throws -> Reply {
        var w = NinePWriter()
        w.u32(fid); w.u64(0); w.u32(UInt32(data.count)); w.bytes(data)
        return try request(NinePType.twrite, w)
    }

    private func request(_ type: UInt8, _ body: NinePWriter) throws -> Reply {
        let message = NinePWriter.message(type: type, tag: 1, body: body.data)
        _ = message.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, message.count) }
        var header = try receive(4)
        let size = Int(try header.u32())
        var rest = try receive(size - 4)
        let replyType = try rest.u8()
        _ = try rest.u16()
        return Reply(type: replyType, body: rest)
    }

    private func receive(_ count: Int) throws -> NinePReader {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let read = data.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress! + offset, count - offset) }
            guard read > 0 else { throw NinePError.protocolError }
            offset += read
        }
        return NinePReader(data)
    }
}
