import Foundation

/// Origin of a published image, including its integrity check (Plan 4.2).
nonisolated struct ImageSource: Codable, Hashable, Sendable {
    let url: URL
    let sha256: String
}

/// Immutable, verified Linux base (BaseImage in the data model).
nonisolated struct BaseImage: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let distribution: String
    let release: String
    let architecture: String
    let catalogVersion: Int
    let downloadSizeBytes: Int64
    let supportedToolchains: [String]
    /// `nil` while the image has not been published yet.
    let source: ImageSource?

    var displayName: String { "\(distribution) \(release)" }
}

/// One distribution with its releases, as offered for selection.
nonisolated struct BaseImageFamily: Identifiable, Hashable, Sendable {
    let distribution: String
    let releases: [BaseImage]

    var id: String { distribution }
}

/// Versioned toolchain profile (ToolchainManifest in the data model): one version of a language
/// or tool. An environment has at most one profile per family, so commands like `node` or `java`
/// always mean the chosen version.
nonisolated struct ToolchainProfile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    /// Language or tool the profile is a version of, for example `nodejs`.
    let family: String
    /// Display name of the family, for example “Node.js”.
    let familyName: String
    /// Display version, for example “24”.
    let version: String
    let revision: Int
    /// Short descriptions keyed by language code; catalog data is localized by the publisher.
    let summaries: [String: String]
    let estimatedSizeBytes: Int64
    /// Prebuilt archives, downloaded and verified by the app and only unpacked inside Linux.
    let packages: [ToolchainPackage]
    /// Commands placed on the `PATH`, mapped to their absolute path inside the guest.
    let commands: [String: String]
    /// Variables set for the editor and its terminals, for example `JAVA_HOME`.
    let environment: [String: String]
    /// Open VSX extensions the profile adds to VS Code.
    let extensions: [String]

    var name: String { "\(familyName) \(version)" }

    var summary: String {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return summaries[language] ?? summaries["en"] ?? ""
    }
}

/// One language or tool with the versions a base offers.
nonisolated struct ToolchainFamily: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let versions: [ToolchainProfile]
}

/// One prebuilt archive of a toolchain profile.
nonisolated struct ToolchainPackage: Codable, Hashable, Sendable {
    enum Format: String, Codable, Sendable {
        case tarGz = "tar.gz"
        case tarXz = "tar.xz"
        case zip
    }

    let url: URL
    let sha256: String
    let format: Format
    let sizeBytes: Int64
    /// Directory inside the guest the archive is unpacked into.
    let installRoot: String
    /// Leading path components dropped while unpacking, as with `tar --strip-components`.
    let stripComponents: Int
}

/// Signed catalog of base images and toolchain profiles (Plan 4.2).
nonisolated struct CatalogDocument: Codable, Sendable {
    var format: Int
    /// Increases with every publication; older documents never replace newer ones.
    var catalogVersion: Int
    var publishedAt: Date
    var baseImages: [BaseImage]
    var toolchains: [ToolchainProfile]

    static let empty = CatalogDocument(format: 1, catalogVersion: 0, publishedAt: .distantPast, baseImages: [], toolchains: [])
}
