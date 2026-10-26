import Foundation

/// Creates empty qcow2 v3 overlays that use an immutable base image as their backing file (ADR05).
///
/// Writing the few header structures directly avoids shipping `qemu-img`. The layout matches what
/// `qemu-img create -f qcow2 -b <base> -F qcow2` produces: header, refcount table, one refcount
/// block, and an empty L1 table, each in its own 64 KiB cluster.
nonisolated enum Qcow2Overlay {
    enum OverlayError: LocalizedError {
        case notQcow2
        case backingPathTooLong

        var errorDescription: String? {
            switch self {
            case .notQcow2: String(localized: "The Linux base is not a valid disk image.")
            case .backingPathTooLong: String(localized: "The Linux base cannot be referenced from the environment.")
            }
        }
    }

    static let magic: UInt32 = 0x5146_49FB // "QFI\xfb"
    private static let clusterBits: UInt32 = 16
    private static let clusterSize = 1 << clusterBits
    private static let backingFormatExtension: UInt32 = 0xE279_2ACA

    /// Virtual disk size in bytes as recorded in a qcow2 header.
    static func virtualSize(of image: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: image)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 32), header.count == 32,
              header.bigEndian(UInt32.self, at: 0) == magic else { throw OverlayError.notQcow2 }
        return header.bigEndian(UInt64.self, at: 24)
    }

    /// Writes a new overlay. The backing file is stored relative to the overlay so the pair keeps
    /// working when iPadOS moves the app container.
    static func create(at overlay: URL, backingFile base: URL) throws {
        let size = try virtualSize(of: base)
        // Created first so symlinks in both paths resolve the same way (for example /var → /private/var).
        try FileManager.default.createDirectory(at: overlay.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backingPath = relativePath(from: overlay.deletingLastPathComponent(), to: base)
        let backing = Data(backingPath.utf8)

        let l2Entries = UInt64(clusterSize / 8)
        let l1Size = UInt32((size + l2Entries * UInt64(clusterSize) - 1) / (l2Entries * UInt64(clusterSize)))
        guard Int(l1Size) * 8 <= clusterSize else { throw OverlayError.notQcow2 }

        var header = Data()
        header.appendBigEndian(magic)
        header.appendBigEndian(UInt32(3))                  // version
        let backingOffsetPosition = header.count
        header.appendBigEndian(UInt64(0))                  // backing_file_offset, patched below
        header.appendBigEndian(UInt32(backing.count))      // backing_file_size
        header.appendBigEndian(clusterBits)
        header.appendBigEndian(size)
        header.appendBigEndian(UInt32(0))                  // crypt_method
        header.appendBigEndian(l1Size)
        header.appendBigEndian(UInt64(3 * clusterSize))    // l1_table_offset
        header.appendBigEndian(UInt64(clusterSize))        // refcount_table_offset
        header.appendBigEndian(UInt32(1))                  // refcount_table_clusters
        header.appendBigEndian(UInt32(0))                  // nb_snapshots
        header.appendBigEndian(UInt64(0))                  // snapshots_offset
        header.appendBigEndian(UInt64(0))                  // incompatible_features
        header.appendBigEndian(UInt64(0))                  // compatible_features
        header.appendBigEndian(UInt64(0))                  // autoclear_features
        header.appendBigEndian(UInt32(4))                  // refcount_order: 16-bit refcounts
        header.appendBigEndian(UInt32(104))                // header_length

        // Backing format extension, so QEMU never probes the format of the base.
        let format = Data("qcow2".utf8)
        header.appendBigEndian(backingFormatExtension)
        header.appendBigEndian(UInt32(format.count))
        header.append(format)
        header.append(Data(count: (8 - format.count % 8) % 8))
        header.appendBigEndian(UInt32(0))                  // end of extensions
        header.appendBigEndian(UInt32(0))

        header.replaceBigEndian(UInt64(header.count), at: backingOffsetPosition)
        header.append(backing)
        guard header.count <= clusterSize else { throw OverlayError.backingPathTooLong }

        var file = Data(count: 4 * clusterSize)
        file.replaceSubrange(0..<header.count, with: header)
        // Refcount table → refcount block in cluster 2.
        file.replaceBigEndian(UInt64(2 * clusterSize), at: clusterSize)
        // Clusters 0 to 3 are in use once each.
        for cluster in 0..<4 {
            file.replaceBigEndian(UInt16(1), at: 2 * clusterSize + cluster * 2)
        }

        try file.write(to: overlay, options: .atomic)
    }

    /// Path of `target` relative to `directory`, for example `../../Images/debian/disk.qcow2`.
    static func relativePath(from directory: URL, to target: URL) -> String {
        let from = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let to = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let common = zip(from, to).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: from.count - common) + to[common...]).joined(separator: "/")
    }
}

private nonisolated extension Data {
    func bigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        self[(startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)].reduce(0) { $0 << 8 | T($1) }
    }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func replaceBigEndian<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        Swift.withUnsafeBytes(of: value.bigEndian) {
            replaceSubrange((startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size), with: $0)
        }
    }
}
