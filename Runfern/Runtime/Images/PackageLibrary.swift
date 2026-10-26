import Foundation

/// Downloads the prebuilt toolchain archives and VS Code extensions an environment needs, verifies
/// them, and keeps them in a folder that Linux mounts read-only (Plan 4.2). Linux then only unpacks:
/// no package manager and no network access are needed inside the guest.
///
/// Files are shared between environments and named after their content, so a download happens once.
@MainActor
final class PackageLibrary {
    enum PackageError: LocalizedError {
        case integrityFailed(String)
        case extensionNotFound(String)
        case offline

        var errorDescription: String? {
            switch self {
            case .integrityFailed(let name): String(localized: "The checksum of \(name) does not match. The file was discarded.")
            case .extensionNotFound(let id): String(localized: "The extension \(id) was not found on Open VSX.")
            case .offline: String(localized: "This download requires an internet connection.")
            }
        }
    }

    /// Mount tag of the package folder in the guest.
    nonisolated static let mountTag = "packages"

    /// Mirrors the global setting “Large downloads over Wi-Fi only” (OFF05).
    var allowsExpensiveNetwork = false {
        didSet {
            session.finishTasksAndInvalidate()
            session = URLSession(configuration: VerifiedDownload.configuration(allowsExpensiveNetwork: allowsExpensiveNetwork))
        }
    }

    private var session = URLSession(configuration: VerifiedDownload.configuration(allowsExpensiveNetwork: false))

    nonisolated static func fileName(for package: ToolchainPackage) -> String {
        "\(package.sha256.lowercased()).\(package.format.rawValue)"
    }

    nonisolated static func extensionFileName(for id: String) -> String {
        "extension-\(id.lowercased()).vsix"
    }

    func isAvailable(_ package: ToolchainPackage) -> Bool {
        FileManager.default.fileExists(atPath: AppPaths.packages.appending(path: Self.fileName(for: package)).path(percentEncoded: false))
    }

    /// Downloads every archive that is not available yet and verifies its checksum.
    func ensureAvailable(_ packages: [ToolchainPackage], isOnline: Bool) async throws {
        let missing = packages.filter { !isAvailable($0) }
        guard !missing.isEmpty else { return }
        guard isOnline else { throw PackageError.offline }
        try DiskUsage.ensureAvailable(missing.reduce(0) { $0 + $1.sizeBytes })
        for package in missing {
            let downloaded = try await download(package.url)
            guard try await VerifiedDownload.verify(downloaded, sha256: package.sha256) else {
                throw PackageError.integrityFailed(package.url.lastPathComponent)
            }
            try store(downloaded, as: Self.fileName(for: package))
        }
    }

    /// Fetches VS Code extensions from Open VSX, preferring builds for Linux on ARM64. Only
    /// well-formed identifiers are fetched, since they become file names, and every file must
    /// match the checksum Open VSX publishes for it.
    func ensureExtensions(_ ids: [String], isOnline: Bool) async throws {
        if let invalid = ids.first(where: { !EditorExtension.isValidID($0) }) { throw PackageError.extensionNotFound(invalid) }
        let missing = ids.filter {
            !FileManager.default.fileExists(atPath: AppPaths.packages.appending(path: Self.extensionFileName(for: $0)).path(percentEncoded: false))
        }
        guard !missing.isEmpty else { return }
        guard isOnline else { throw PackageError.offline }
        for id in missing {
            let files = try await openVSXFiles(for: id)
            guard let checksumURL = files.sha256, checksumURL.scheme == "https", files.download.scheme == "https" else {
                throw PackageError.integrityFailed(id)
            }
            let (data, _) = try await session.data(from: checksumURL)
            let expected = String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
            let downloaded = try await download(files.download)
            guard try await VerifiedDownload.verify(downloaded, sha256: expected) else {
                throw PackageError.integrityFailed(id)
            }
            try store(downloaded, as: Self.extensionFileName(for: id))
        }
    }

    // MARK: Private

    private struct OpenVSXFiles: Decodable {
        let download: URL
        let sha256: URL?
    }

    private struct OpenVSXExtension: Decodable {
        let files: OpenVSXFiles
    }

    private func openVSXFiles(for id: String) async throws -> OpenVSXFiles {
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw PackageError.extensionNotFound(id) }
        let base = URL(string: "https://open-vsx.org/api")!.appending(path: parts[0]).appending(path: parts[1])
        // Platform-specific builds exist for extensions with native code; the universal build otherwise.
        for url in [base.appending(path: "linux-arm64"), base] {
            let (data, response) = try await session.data(from: url)
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let decoded = try? JSONDecoder().decode(OpenVSXExtension.self, from: data) {
                return decoded.files
            }
        }
        throw PackageError.extensionNotFound(id)
    }

    private func download(_ url: URL) async throws -> URL {
        let (location, response) = try await session.download(from: url)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: location)
            throw URLError(.badServerResponse)
        }
        return location
    }

    private func store(_ file: URL, as name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: AppPaths.packages, withIntermediateDirectories: true)
        let target = AppPaths.packages.appending(path: name)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: file, to: target)
    }
}
