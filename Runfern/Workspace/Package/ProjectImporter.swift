import Foundation

/// Imports a project package created by `ProjectExporter` (NEW05, DAT05 V1).
/// Everything is extracted and verified in a private staging folder before a project is registered.
nonisolated enum ProjectImporter {
    struct Preview: Sendable {
        var projectName: String
        let fileCount: Int
        let totalBytes: Int64
        let recipe: EnvironmentRecipe?
        /// Recipe components the active catalog cannot provide.
        let missingComponents: [String]
        fileprivate let staging: URL
        fileprivate let filesRoot: URL
    }

    enum ImportError: LocalizedError {
        case missingManifest
        case contentMismatch(String)
        case missingRecipe

        var errorDescription: String? {
            switch self {
            case .missingManifest:
                String(localized: "The archive is not a Runfern project package (manifest missing).")
            case .contentMismatch(let path):
                String(localized: "The package content does not match its checksum list at “\(path)”.")
            case .missingRecipe:
                String(localized: "The package has no usable environment recipe for this catalog.")
            }
        }
    }

    /// Extracts and verifies the archive. Nothing outside the staging folder is touched.
    static func prepare(archive: URL) throws -> Preview {
        let reader = try ZipArchiveReader(url: archive)
        try DiskUsage.ensureAvailable(Int64(reader.totalUncompressedSize))
        let staging = AppPaths.imports.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try reader.extract(to: staging)
            return try verify(staging: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Registers the project and moves the verified files into its new working copy.
    @MainActor
    static func commit(_ preview: Preview, store: ProjectStore, binding: WorkspaceBinding) throws -> Project {
        guard let recipe = preview.recipe, let image = Catalog.baseImage(id: recipe.base.id) else {
            throw ImportError.missingRecipe
        }
        let toolchains = recipe.toolchains.compactMap { Catalog.toolchain(id: $0.id) }
        let project = try store.createProject(name: preview.projectName, details: "", source: .empty,
                                              baseImage: image, toolchains: toolchains, binding: binding)
        let workingCopy = AppPaths.workingCopy(binding.id)
        do {
            try FileManager.default.createDirectory(at: workingCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: preview.filesRoot, to: workingCopy)
        } catch {
            store.remove(project)
            throw error
        }
        discard(preview)
        return project
    }

    static func discard(_ preview: Preview) {
        try? FileManager.default.removeItem(at: preview.staging)
    }

    // MARK: Private

    private static func verify(staging: URL) throws -> Preview {
        let root = try packageRoot(in: staging)
        guard let manifestData = try? Data(contentsOf: root.appending(path: "manifest.json")) else {
            throw ImportError.missingManifest
        }
        let manifest = try JSONDecoder.store.decode(ProjectExporter.Manifest.self, from: manifestData)

        let filesRoot = root.appending(path: "files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        let files = try DirectoryScanner.scan(filesRoot, cache: [:]).records.filter { !$0.value.isDirectory }
        // Exactly the listed files, each with the listed checksum.
        if let unexpected = Set(files.keys).symmetricDifference(manifest.files.keys).sorted().first {
            throw ImportError.contentMismatch(unexpected)
        }
        for (path, hash) in manifest.files where files[path]?.hash != hash {
            throw ImportError.contentMismatch(path)
        }

        let recipe = (try? Data(contentsOf: root.appending(path: "runfern-recipe.json")))
            .flatMap { try? JSONDecoder().decode(EnvironmentRecipe.self, from: $0) }
        var missing: [String] = []
        if let recipe {
            if Catalog.baseImage(id: recipe.base.id) == nil { missing.append(String(localized: "Linux base \(recipe.base.id)")) }
            missing += recipe.toolchains.filter { Catalog.toolchain(id: $0.id) == nil }
                .map { String(localized: "Toolchain profile \($0.id)") }
        } else {
            missing.append(String(localized: "Environment recipe"))
        }

        return Preview(projectName: manifest.project, fileCount: files.count,
                       totalBytes: files.values.reduce(0) { $0 + $1.size }, recipe: recipe,
                       missingComponents: missing, staging: staging, filesRoot: filesRoot)
    }

    /// The package is either the archive root or its single top-level folder.
    private static func packageRoot(in staging: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.appending(path: "manifest.json").path(percentEncoded: false)) { return staging }
        let children = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("__MACOSX") }
        if children.count == 1,
           fm.fileExists(atPath: children[0].appending(path: "manifest.json").path(percentEncoded: false)) {
            return children[0]
        }
        throw ImportError.missingManifest
    }
}
