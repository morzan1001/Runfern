import Foundation

/// Rules shared by everything Runfern downloads: sessions follow the “Wi-Fi only” setting, and
/// files are used only once their SHA-256 checksum matches.
nonisolated enum VerifiedDownload {
    static func configuration(allowsExpensiveNetwork: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        configuration.allowsConstrainedNetworkAccess = false
        return configuration
    }

    /// Whether `file` has the checksum `sha256`. A file that doesn't is deleted right away.
    static func verify(_ file: URL, sha256 expected: String) async throws -> Bool {
        let hash = try await Task.detached(priority: .utility) { try DirectoryScanner.sha256(of: file) }.value
        guard hash.caseInsensitiveCompare(expected.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else {
            try? FileManager.default.removeItem(at: file)
            return false
        }
        return true
    }
}
