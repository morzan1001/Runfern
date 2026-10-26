import Foundation

/// Exports project files and the environment recipe into a verifiable archive (DAT05, Plan 2.6).
/// App-managed credentials are never included; the app cannot detect secrets inside project files themselves.
nonisolated enum ProjectExporter {
    struct Preview: Sendable {
        let fileCount: Int
        let totalBytes: Int64
        let excludedNames: [String]
    }

    /// Verifiable table of contents inside the archive.
    struct Manifest: Codable {
        var format = 1
        let project: String
        let createdAt: Date
        let scope: String
        let excluded: [String]
        let files: [String: String]   // relative path → SHA-256
    }

    enum ExportError: LocalizedError {
        case verificationFailed(String)
        case archiveFailed

        var errorDescription: String? {
            switch self {
            case .verificationFailed(let path): String(localized: "Export verification failed at “\(path)”.")
            case .archiveFailed: String(localized: "The archive could not be created.")
            }
        }
    }

    static func preview(workingCopy: URL) throws -> Preview {
        let records = try DirectoryScanner.scan(workingCopy, cache: [:]).records.values.filter { !$0.isDirectory }
        return Preview(fileCount: records.count, totalBytes: records.reduce(0) { $0 + $1.size },
                       excludedNames: DirectoryScanner.excludedNames.sorted())
    }

    /// Creates `<Project>.zip` containing `files/`, `runfern-recipe.json`, and `manifest.json`.
    static func export(projectName: String, workingCopy: URL, recipe: EnvironmentRecipe?) throws -> URL {
        let fm = FileManager.default
        let safeName = projectName.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        let staging = AppPaths.exports.appending(path: UUID().uuidString).appending(path: safeName, directoryHint: .isDirectory)
        let filesRoot = staging.appending(path: "files", directoryHint: .isDirectory)
        try fm.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }

        // Copy only synced content; regenerable caches stay out.
        let source = try DirectoryScanner.scan(workingCopy, cache: [:]).records
        for (path, record) in source.sorted(by: { $0.key < $1.key }) {
            let target = filesRoot.appending(path: path)
            if record.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: workingCopy.appending(path: path), to: target)
            }
        }

        // Verify the copy against the source before the export counts as finished.
        let copied = try DirectoryScanner.scan(filesRoot, cache: [:]).records
        for (path, record) in source where !record.isDirectory {
            guard copied[path]?.hash == record.hash else { throw ExportError.verificationFailed(path) }
        }

        let encoder = JSONEncoder.store
        let manifest = Manifest(
            project: projectName, createdAt: .now,
            scope: "Project files and environment recipe. No Linux system data, no app-managed credentials.",
            excluded: DirectoryScanner.excludedNames.sorted(),
            files: source.compactMapValues(\.hash)
        )
        try encoder.encode(manifest).write(to: staging.appending(path: "manifest.json"))
        if let recipe {
            try encoder.encode(recipe).write(to: staging.appending(path: "runfern-recipe.json"))
        }

        // NSFileCoordinator produces a ZIP of the folder when reading with “forUploading”.
        let archive = AppPaths.exports.appending(path: "\(safeName).zip")
        try? fm.removeItem(at: archive)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinationError) { zipURL in
            do { try fm.copyItem(at: zipURL, to: archive) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError.map({ $0 as NSError }) { throw error }
        guard fm.fileExists(atPath: archive.path(percentEncoded: false)) else { throw ExportError.archiveFailed }
        return archive
    }
}
