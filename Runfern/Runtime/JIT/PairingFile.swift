#if RUNFERN_JIT
import Foundation

/// The iPad's pairing record for its developer services, which the built-in JIT needs. A computer
/// creates it once (for example `idevice_pair` on a Mac); Runfern keeps the imported copy in its
/// own container, protected and excluded from backups, and never logs or exports it.
nonisolated enum PairingFile {
    enum ImportError: LocalizedError {
        case invalid

        var errorDescription: String? {
            String(localized: "The file is not a pairing file.")
        }
    }

    static var url: URL { AppPaths.pairingFile }

    static var isImported: Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// The pairing record, if one was imported.
    static func load() -> Data? {
        try? Data(contentsOf: url)
    }

    /// Copies the file at `source` (from the document picker) into Runfern, replacing an earlier one.
    static func importFile(at source: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let data = try read(source)
        guard let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              record["HostID"] != nil || record["HostCertificate"] != nil else {
            throw ImportError.invalid
        }
        var destination = url
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
    }

    /// Pairing records are small property lists with the host's identity and certificates, so
    /// at most `maximumSize` bytes are read. The read is coordinated, which also downloads a file
    /// that is still in iCloud Drive (for example one sent with AirDrop to iCloud Downloads).
    private static func read(_ source: URL) throws -> Data {
        let maximumSize = 256 * 1024
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(ImportError.invalid)
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordinationError) { url in
            result = Result {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
                guard !data.isEmpty, data.count <= maximumSize else { throw ImportError.invalid }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
