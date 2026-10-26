import Foundation

/// Streams the regular files of a POSIX ustar archive into a directory.
///
/// Image bundles are created by Runfern's own build script, so only the plain ustar subset is
/// supported. Entries that would leave the target directory are rejected.
nonisolated enum TarExtractor {
    enum TarError: LocalizedError {
        case malformed
        case unsafePath(String)

        var errorDescription: String? {
            switch self {
            case .malformed: String(localized: "The archive is damaged.")
            case .unsafePath(let path): String(localized: "The archive contains an unsafe path: \(path)")
            }
        }
    }

    private static let blockSize = 512
    private static let chunkSize = 4 << 20

    /// Returns the relative paths of the extracted files.
    @discardableResult
    static func extract(_ archive: URL, to directory: URL) throws -> [String] {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var extracted: [String] = []
        while true {
            guard let header = try input.read(upToCount: blockSize), header.count == blockSize else { throw TarError.malformed }
            // Two zero blocks end the archive; one is enough to stop reading.
            if header.allSatisfy({ $0 == 0 }) { break }
            guard header[257..<262].elementsEqual("ustar".utf8) else { throw TarError.malformed }

            let name = string(header, 0, 100)
            let prefix = string(header, 345, 155)
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            guard let size = Int(string(header, 124, 12).trimmingCharacters(in: .whitespaces), radix: 8) else {
                throw TarError.malformed
            }
            let type = header[156]
            let padded = (size + blockSize - 1) / blockSize * blockSize

            switch type {
            case UInt8(ascii: "0"), 0:
                let target = try safeTarget(path, in: directory)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: target.path(percentEncoded: false), contents: nil)
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                var remaining = size
                while remaining > 0 {
                    guard let chunk = try input.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else {
                        throw TarError.malformed
                    }
                    try output.write(contentsOf: chunk)
                    remaining -= chunk.count
                }
                try input.seek(toOffset: try input.offset() + UInt64(padded - size))
                extracted.append(path)
            case UInt8(ascii: "5"):
                try fm.createDirectory(at: try safeTarget(path, in: directory), withIntermediateDirectories: true)
            default:
                // Metadata entries (for example pax headers) carry nothing Runfern needs.
                try input.seek(toOffset: try input.offset() + UInt64(padded))
            }
        }
        return extracted
    }

    private static func string(_ block: Data, _ offset: Int, _ length: Int) -> String {
        let field = block[(block.startIndex + offset)..<(block.startIndex + offset + length)]
        return String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func safeTarget(_ path: String, in directory: URL) throws -> URL {
        let components = path.split(separator: "/").filter { $0 != "." }
        guard !path.hasPrefix("/"), !components.isEmpty, !components.contains("..") else { throw TarError.unsafePath(path) }
        return components.reduce(directory) { $0.appending(path: String($1)) }
    }
}
