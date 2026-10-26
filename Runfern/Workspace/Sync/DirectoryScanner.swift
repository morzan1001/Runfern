import CryptoKit
import Foundation

nonisolated enum DirectoryScanner {
    static let temporaryPrefix = ".runfern-tmp-"

    /// Regenerable content that is not synced. Git metadata is explicitly not part of this.
    static let excludedNames: Set<String> = [".DS_Store", "__pycache__", ".venv", "node_modules", ".Trash", ".Trashes"]

    static func isExcluded(_ name: String) -> Bool {
        excludedNames.contains(name) || name.hasPrefix(temporaryPrefix) || name.hasSuffix(".pyc")
    }

    struct Result {
        var records: [String: FileRecord] = [:]
        var unsupported: [String] = []
        /// Files that exist but whose content is not on the device yet (evicted cloud files).
        /// They must never be treated as deleted or changed (FIL05, R04).
        var pending: Set<String> = []
    }

    /// Asks the file provider to bring an evicted cloud file back to the device.
    static func requestDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Reads the complete inventory. A read error aborts so that deletions are never inferred
    /// from an incomplete directory listing (Plan 4.5).
    static func scan(_ root: URL, cache: [String: FileRecord],
                     requestDownload: (URL) -> Void = DirectoryScanner.requestDownload) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path(percentEncoded: false)) else {
            throw SyncError.listingFailed(String(localized: "Folder does not exist"))
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
                                      .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var failure: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, error in
            failure = error
            return false
        }) else { throw SyncError.listingFailed(String(localized: "Folder is not readable")) }

        var result = Result()
        for case let url as URL in enumerator {
            // `level` is the depth relative to the root, which is robust against /private prefixes.
            let path = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            if isExcluded(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                result.unsupported.append(path)
                continue
            }
            if let original = placeholderTarget(of: url.lastPathComponent) {
                // Legacy iCloud placeholder ".name.icloud": the real file exists but is evicted.
                let directory = (path as NSString).deletingLastPathComponent
                result.pending.insert(directory.isEmpty ? original : "\(directory)/\(original)")
                requestDownload(url.deletingLastPathComponent().appending(path: original))
                continue
            }
            if values.isUbiquitousItem == true, values.isDirectory != true,
               values.ubiquitousItemDownloadingStatus != .current {
                // Reading would block on the network; wait until the provider has the current version.
                result.pending.insert(path)
                requestDownload(url)
                continue
            }
            let modified = values.contentModificationDate ?? .distantPast
            if values.isDirectory == true {
                result.records[path] = FileRecord(isDirectory: true, size: 0, modified: modified, hash: nil, isExecutable: false)
                continue
            }
            guard values.isRegularFile == true else {
                result.unsupported.append(path)
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            let permissions = (try? fm.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int) ?? 0
            let hash: String
            if let cached = cache[path], !cached.isDirectory, cached.size == size,
               abs(cached.modified.timeIntervalSince(modified)) < 0.001, let cachedHash = cached.hash {
                hash = cachedHash
            } else {
                hash = try sha256(of: url)
            }
            result.records[path] = FileRecord(isDirectory: false, size: size, modified: modified,
                                              hash: hash, isExecutable: permissions & 0o111 != 0)
        }
        if let failure { throw SyncError.listingFailed(failure.localizedDescription) }
        return result
    }

    /// Original file name for a legacy iCloud placeholder such as ".main.py.icloud".
    static func placeholderTarget(of name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".x.icloud".count - 1 else { return nil }
        let original = String(name.dropFirst().dropLast(".icloud".count))
        return original.isEmpty ? nil : original
    }

    /// Current state of a single path, without cache.
    static func record(at url: URL) throws -> FileRecord? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else { return nil }
        let attributes = try fm.attributesOfItem(atPath: url.path(percentEncoded: false))
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        if isDirectory.boolValue {
            return FileRecord(isDirectory: true, size: 0, modified: modified, hash: nil, isExecutable: false)
        }
        let permissions = attributes[.posixPermissions] as? Int ?? 0
        return FileRecord(isDirectory: false, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                          modified: modified, hash: try sha256(of: url), isExecutable: permissions & 0o111 != 0)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
