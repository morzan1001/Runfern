import Compression
import Foundation

/// Minimal, defensive ZIP reader for project packages (NEW05).
/// Supports stored and deflated entries; rejects encryption, ZIP64, symbolic links,
/// and any path that could escape the destination ("zip slip").
nonisolated struct ZipArchiveReader {
    enum ZipError: LocalizedError, Equatable {
        case notAnArchive
        case unsupported(String)
        case unsafePath(String)
        case corrupted(String)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notAnArchive: String(localized: "The file is not a valid ZIP archive.")
            case .unsupported(let feature): String(localized: "The archive uses an unsupported feature (\(feature)).")
            case .unsafePath(let path): String(localized: "The archive contains an unsafe path: \(path)")
            case .corrupted(let path): String(localized: "The archive entry “\(path)” is damaged.")
            case .tooLarge: String(localized: "The archive is too large to import.")
            }
        }
    }

    struct Entry: Hashable, Sendable {
        let path: String
        let isDirectory: Bool
        let method: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Guards against archive bombs.
    static let maximumEntries = 50_000
    static let maximumTotalSize = 4 * 1024 * 1024 * 1024

    let entries: [Entry]
    private let data: Data

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        entries = try Self.readCentralDirectory(data)
        guard entries.count <= Self.maximumEntries,
              entries.reduce(0, { $0 + $1.uncompressedSize }) <= Self.maximumTotalSize else { throw ZipError.tooLarge }
    }

    var totalUncompressedSize: Int { entries.reduce(0) { $0 + $1.uncompressedSize } }

    /// Decompresses one entry and verifies its checksum.
    func contents(of entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard data.count >= header + 30, data.uint32(at: header) == 0x0403_4B50 else { throw ZipError.corrupted(entry.path) }
        let start = header + 30 + Int(data.uint16(at: header + 26)) + Int(data.uint16(at: header + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError.corrupted(entry.path) }
        let compressed = data.subdata(in: start..<(start + entry.compressedSize))

        let output: Data
        switch entry.method {
        case 0:
            output = compressed
        case 8:
            output = try Self.inflate(compressed, expectedSize: entry.uncompressedSize, path: entry.path)
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard output.count == entry.uncompressedSize, CRC32.checksum(output) == entry.crc32 else {
            throw ZipError.corrupted(entry.path)
        }
        return output
    }

    /// Extracts all entries below `destination`, which must not exist yet.
    func extract(to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in entries {
            let target = destination.appending(path: entry.path)
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents(of: entry).write(to: target, options: .withoutOverwriting)
            }
        }
    }

    // MARK: Parsing

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        // The end-of-central-directory record sits within the last 64 KiB + 22 bytes.
        guard data.count >= 22 else { throw ZipError.notAnArchive }
        let searchStart = max(0, data.count - 65_557)
        guard let eocd = stride(from: data.count - 22, through: searchStart, by: -1)
            .first(where: { data.uint32(at: $0) == 0x0605_4B50 }) else { throw ZipError.notAnArchive }

        let count = Int(data.uint16(at: eocd + 10))
        let offset = Int(data.uint32(at: eocd + 16))
        guard count != 0xFFFF, offset != 0xFFFF_FFFF else { throw ZipError.unsupported("ZIP64") }

        var entries: [Entry] = []
        var position = offset
        for _ in 0..<count {
            guard position + 46 <= data.count, data.uint32(at: position) == 0x0201_4B50 else { throw ZipError.notAnArchive }
            let flags = data.uint16(at: position + 8)
            let method = data.uint16(at: position + 10)
            let crc = data.uint32(at: position + 16)
            let compressed = data.uint32(at: position + 20)
            let uncompressed = data.uint32(at: position + 24)
            let nameLength = Int(data.uint16(at: position + 28))
            let extraLength = Int(data.uint16(at: position + 30))
            let commentLength = Int(data.uint16(at: position + 32))
            let externalAttributes = data.uint32(at: position + 38)
            let localOffset = data.uint32(at: position + 42)
            guard position + 46 + nameLength <= data.count else { throw ZipError.notAnArchive }
            let path = String(decoding: data.subdata(in: (position + 46)..<(position + 46 + nameLength)), as: UTF8.self)

            guard flags & 0x1 == 0 else { throw ZipError.unsupported("encryption") }
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw ZipError.unsupported("ZIP64")
            }
            // Unix mode lives in the upper 16 bits; symbolic links could point outside the destination.
            let unixMode = externalAttributes >> 16
            guard unixMode & 0xF000 != 0xA000 else { throw ZipError.unsafePath(path) }
            try validate(path)

            entries.append(Entry(path: path, isDirectory: path.hasSuffix("/"), method: method, crc32: crc,
                                 compressedSize: Int(compressed), uncompressedSize: Int(uncompressed),
                                 localHeaderOffset: Int(localOffset)))
            position += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Only relative paths without parent references, drive letters, or backslashes are allowed.
    static func validate(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.contains("\0"),
              !components.dropLast().contains(where: { $0.isEmpty }),
              !components.contains(where: { $0 == ".." || $0 == "." }) else {
            throw ZipError.unsafePath(path)
        }
    }

    private static func inflate(_ input: Data, expectedSize: Int, path: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP stores.
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          source.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.corrupted(path) }
        return output
    }
}

/// CRC-32 (IEEE 802.3), as used by ZIP.
nonisolated enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}

private nonisolated extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
