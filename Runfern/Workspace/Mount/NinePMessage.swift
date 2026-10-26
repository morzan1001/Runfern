import Foundation

/// Little-endian reader and writer for 9P2000.L messages.
nonisolated struct NinePReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func u8() throws -> UInt8 { try integer() }
    mutating func u16() throws -> UInt16 { try integer() }
    mutating func u32() throws -> UInt32 { try integer() }
    mutating func u64() throws -> UInt64 { try integer() }

    mutating func string() throws -> String {
        let length = Int(try u16())
        return String(decoding: try bytes(length), as: UTF8.self)
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw NinePError.protocolError }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    private mutating func integer<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        let slice = try bytes(size)
        return slice.reversed().reduce(T(0)) { $0 << 8 | T($1) }
    }
}

nonisolated struct NinePWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { append(value) }
    mutating func u32(_ value: UInt32) { append(value) }
    mutating func u64(_ value: UInt64) { append(value) }

    mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        u16(UInt16(bytes.count))
        data.append(bytes)
    }

    mutating func bytes(_ value: Data) { data.append(value) }

    mutating func qid(_ qid: NinePQid) {
        u8(qid.type)
        u32(qid.version)
        u64(qid.path)
    }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Wraps a body into a complete message with size, type, and tag.
    static func message(type: UInt8, tag: UInt16, body: Data) -> Data {
        var writer = NinePWriter()
        writer.u32(UInt32(7 + body.count))
        writer.u8(type)
        writer.u16(tag)
        writer.bytes(body)
        return writer.data
    }
}

/// Identity of a file for the client: kind, version, and a unique number (the inode).
nonisolated struct NinePQid: Sendable {
    static let directory: UInt8 = 0x80
    static let symlink: UInt8 = 0x02
    static let file: UInt8 = 0x00

    let type: UInt8
    let version: UInt32
    let path: UInt64

    init(_ info: stat) {
        switch info.st_mode & S_IFMT {
        case S_IFDIR: type = Self.directory
        case S_IFLNK: type = Self.symlink
        default: type = Self.file
        }
        version = UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec)
        path = UInt64(info.st_ino)
    }
}

/// A failed request; answered with Rlerror and a Linux errno.
nonisolated enum NinePError: Error {
    case errno(Int32)
    case protocolError

    /// Linux numbering, which the guest expects (differs from Darwin for some values).
    var linuxCode: UInt32 {
        switch self {
        case .protocolError: return 71 // EPROTO
        case .errno(let code):
            switch code {
            case ENOTEMPTY: return 39
            case ENAMETOOLONG: return 36
            case ENOTSUP, EOPNOTSUPP: return 95
            case ELOOP: return 40
            case EDQUOT: return 122
            case ENOSYS: return 38
            case EAGAIN: return 11
            // EPERM…ERANGE share their numbers below 35; anything else becomes EIO.
            default: return code < 35 ? UInt32(code) : 5
            }
        }
    }

    static var current: NinePError { .errno(Darwin.errno) }
}

/// 9P2000.L message types used by Linux' v9fs client.
nonisolated enum NinePType {
    static let rlerror: UInt8 = 7
    static let tstatfs: UInt8 = 8
    static let tlopen: UInt8 = 12
    static let tlcreate: UInt8 = 14
    static let tsymlink: UInt8 = 16
    static let tmknod: UInt8 = 18
    static let trename: UInt8 = 20
    static let treadlink: UInt8 = 22
    static let tgetattr: UInt8 = 24
    static let tsetattr: UInt8 = 26
    static let txattrwalk: UInt8 = 30
    static let txattrcreate: UInt8 = 32
    static let treaddir: UInt8 = 40
    static let tfsync: UInt8 = 50
    static let tlock: UInt8 = 52
    static let tgetlock: UInt8 = 54
    static let tlink: UInt8 = 70
    static let tmkdir: UInt8 = 72
    static let trenameat: UInt8 = 74
    static let tunlinkat: UInt8 = 76
    static let tversion: UInt8 = 100
    static let tauth: UInt8 = 102
    static let tattach: UInt8 = 104
    static let tflush: UInt8 = 108
    static let twalk: UInt8 = 110
    static let tread: UInt8 = 116
    static let twrite: UInt8 = 118
    static let tclunk: UInt8 = 120
    static let tremove: UInt8 = 122
}
