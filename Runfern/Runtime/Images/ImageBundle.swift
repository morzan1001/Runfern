import Foundation

/// An installed Linux base: system disk, kernel, and initial RAM disk for direct kernel boot.
///
/// Images are published as ustar archives with this layout:
///
///     image.json   manifest (format, kernel command line, agent protocol)
///     disk.qcow2   immutable system disk, the backing file of every overlay
///     vmlinuz      kernel
///     initrd.img   initial RAM disk
///
/// Booting the kernel directly skips the UEFI firmware, which saves noticeable time without JIT.
nonisolated struct ImageBundle: Sendable {
    struct Manifest: Codable, Sendable {
        let format: Int
        let kernelCommandLine: String
        let agentProtocolVersion: Int
        /// Unique per image build. Overlays only work on the exact base they were created on.
        let buildID: String?
    }

    enum BundleError: LocalizedError {
        case incomplete
        case incompatible
        case baseReplaced

        var errorDescription: String? {
            switch self {
            case .incomplete: String(localized: "The Linux base is incomplete.")
            case .incompatible: String(localized: "This Linux base requires a newer version of Runfern.")
            case .baseReplaced: String(localized: "The Linux base of this environment was replaced. Reset the environment to set it up on the new base.")
            }
        }
    }

    static let supportedFormat = 1
    static let requiredFiles = ["image.json", "disk.qcow2", "vmlinuz", "initrd.img"]

    let directory: URL

    var disk: URL { directory.appending(path: "disk.qcow2") }
    var kernel: URL { directory.appending(path: "vmlinuz") }
    var initrd: URL { directory.appending(path: "initrd.img") }

    func manifest() throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appending(path: "image.json")))
        guard manifest.format <= Self.supportedFormat, manifest.agentProtocolVersion == agentProtocolVersion else {
            throw BundleError.incompatible
        }
        return manifest
    }

    /// Unpacks a verified archive and installs it atomically at `target`. The files are marked
    /// immutable; changes only ever go into an environment's overlay.
    static func install(archive: URL, to target: URL) throws {
        let fm = FileManager.default
        let staging = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).staging")
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }

        try TarExtractor.extract(archive, to: staging)
        let bundle = ImageBundle(directory: staging)
        guard requiredFiles.allSatisfy({ fm.fileExists(atPath: staging.appending(path: $0).path(percentEncoded: false)) }) else {
            throw BundleError.incomplete
        }
        _ = try bundle.manifest()
        _ = try Qcow2Overlay.virtualSize(of: bundle.disk)

        try? remove(target)
        try fm.moveItem(at: staging, to: target)
        for file in requiredFiles {
            try fm.setAttributes([.immutable: true], ofItemAtPath: target.appending(path: file).path(percentEncoded: false))
        }
    }

    /// Removes an installed bundle including its immutable files.
    static func remove(_ directory: URL) throws {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.setAttributes([.immutable: false], ofItemAtPath: file.path(percentEncoded: false))
        }
        try fm.removeItem(at: directory)
    }
}
