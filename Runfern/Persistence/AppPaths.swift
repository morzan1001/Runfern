import Foundation

/// Location of all app-managed data. Project data and system data are kept apart (ADR06, Plan 4.3).
///
///     Runfern/
///       store.json                 projects, environments, bindings
///       Catalog/catalog.json(.sig) newest verified catalog
///       Diagnostics/events.jsonl   redacted local diagnostic journal
///       Images/<id>[-v<n>]/        shared, immutable base images (see ImageBundle)
///       Downloads/                 partially downloaded images
///       Packages/                  verified toolchain archives and VS Code extensions
///       Environments/<id>/         overlay and recipe of an environment
///       Workspaces/<id>/files/     local working copy of a project
///       Workspaces/<id>/sync.json  sync baseline and journal
///       Workspaces/<id>/Conflicts/ preserved conflict versions
nonisolated enum AppPaths {
    static let root = URL.applicationSupportDirectory.appending(path: "Runfern", directoryHint: .isDirectory)

    static var store: URL { root.appending(path: "store.json") }
    static var catalogCache: URL { root.appending(path: "Catalog/catalog.json") }
    static var diagnostics: URL { root.appending(path: "Diagnostics/events.jsonl") }
    /// The iPad's pairing record for the built-in JIT (JIT builds only).
    static var pairingFile: URL { root.appending(path: "JIT/pairingFile.plist") }
    static var images: URL { root.appending(path: "Images", directoryHint: .isDirectory) }
    static var downloads: URL { root.appending(path: "Downloads", directoryHint: .isDirectory) }
    static var packages: URL { root.appending(path: "Packages", directoryHint: .isDirectory) }
    static var environments: URL { root.appending(path: "Environments", directoryHint: .isDirectory) }
    static var workspaces: URL { root.appending(path: "Workspaces", directoryHint: .isDirectory) }
    static var exports: URL { URL.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory) }
    static var imports: URL { URL.temporaryDirectory.appending(path: "Imports", directoryHint: .isDirectory) }

    /// Every published version of a base lives in its own directory: overlays reference their exact
    /// base, so a newer version must never replace the files of an older one (ADR05).
    static func image(_ id: String, version: Int) -> URL {
        images.appending(path: imageDirectoryName(id, version: version), directoryHint: .isDirectory)
    }

    /// Version 1 predates versioned directories and keeps the plain name.
    static func imageDirectoryName(_ id: String, version: Int) -> String {
        version <= 1 ? id : "\(id)-v\(version)"
    }
    static func environment(_ id: UUID) -> URL { environments.appending(path: id.uuidString, directoryHint: .isDirectory) }
    static func overlay(_ id: UUID) -> URL { environment(id).appending(path: "system.qcow2") }
    static func recipe(_ id: UUID) -> URL { environment(id).appending(path: "recipe.json") }
    static func workspaceRoot(_ id: UUID) -> URL { workspaces.appending(path: id.uuidString, directoryHint: .isDirectory) }
    static func workingCopy(_ id: UUID) -> URL { workspaceRoot(id).appending(path: "files", directoryHint: .isDirectory) }
    static func syncState(_ id: UUID) -> URL { workspaceRoot(id).appending(path: "sync.json") }
    static func conflicts(_ id: UUID) -> URL { workspaceRoot(id).appending(path: "Conflicts", directoryHint: .isDirectory) }

    /// Creates the directory layout. Re-downloadable images are excluded from device backups.
    static func prepare() {
        let fm = FileManager.default
        for dir in [images, downloads, packages, environments, workspaces] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for var dir in [images, downloads, packages] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
    }
}
