import CryptoKit
import Foundation
import Observation
import Synchronization

/// Verifies catalog documents against the publisher's Ed25519 key (Plan 4.2).
nonisolated struct CatalogVerifier: Sendable {
    /// Public key of the Runfern catalog publisher. The private key never ships with the app.
    static let publisherKey = "SzSGomipAmxhFBSIPmMYmiyKrJ/K9X3/uG+lurxn5HY="

    enum VerificationError: LocalizedError {
        case invalidSignature
        case unreadable
        case outdated(current: Int, offered: Int)

        var errorDescription: String? {
            switch self {
            case .invalidSignature:
                String(localized: "The catalog signature is invalid. The catalog was not installed.")
            case .unreadable:
                String(localized: "The catalog could not be read.")
            case let .outdated(current, offered):
                String(localized: "The offered catalog (version \(offered)) is not newer than the installed one (version \(current)).")
            }
        }
    }

    let publicKey: Curve25519.Signing.PublicKey

    init(publicKeyBase64: String = Self.publisherKey) {
        // The key is a compile-time constant; failing here is a programming error.
        publicKey = try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicKeyBase64)!)
    }

    /// Returns the decoded document only if the signature covers exactly these bytes.
    func verifiedDocument(data: Data, signature: Data) throws -> CatalogDocument {
        let decodedSignature = Data(base64Encoded: String(decoding: signature, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? signature
        guard publicKey.isValidSignature(decodedSignature, for: data) else { throw VerificationError.invalidSignature }
        do {
            return try JSONDecoder.catalog.decode(CatalogDocument.self, from: data)
        } catch {
            throw VerificationError.unreadable
        }
    }
}

/// The catalog that is currently in effect, readable from any isolation domain.
/// Loaded lazily on first access: a verified newer cached catalog wins over the bundled one.
nonisolated let activeCatalog = Mutex<CatalogDocument>(CatalogStore.loadInitialDocument())

/// Manages the active catalog: bundled baseline, verified cache, and updates (Plan 4.2, OFF05).
@Observable
final class CatalogStore {
    private(set) var catalogVersion: Int
    private(set) var publishedAt: Date
    private(set) var lastError: String?
    private(set) var isChecking = false

    /// The published catalog in the Runfern repository (`Catalog/catalog.json`); its signature
    /// lies next to it. Whoever serves the files doesn't matter: only a catalog signed with the
    /// publisher key and newer than the active one is installed.
    static let updateURL: URL? = URL(string: "https://raw.githubusercontent.com/morzan1001/Runfern/main/Catalog/catalog.json")

    private let verifier: CatalogVerifier
    private let cacheURL: URL

    init(verifier: CatalogVerifier = CatalogVerifier(), cacheURL: URL = AppPaths.catalogCache) {
        self.verifier = verifier
        self.cacheURL = cacheURL
        let current = activeCatalog.withLock { $0 }
        catalogVersion = current.catalogVersion
        publishedAt = current.publishedAt
    }

    /// Installs a signed catalog if it is valid and newer than the active one.
    /// Existing environments keep their exact base version regardless (IMG02).
    func install(data: Data, signature: Data) throws {
        let document = try verifier.verifiedDocument(data: data, signature: signature)
        let current = activeCatalog.withLock { $0.catalogVersion }
        guard document.catalogVersion > current else {
            throw CatalogVerifier.VerificationError.outdated(current: current, offered: document.catalogVersion)
        }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        try signature.write(to: Self.signatureURL(for: cacheURL), options: .atomic)
        activeCatalog.withLock { $0 = document }
        catalogVersion = document.catalogVersion
        publishedAt = document.publishedAt
        lastError = nil
    }

    /// Downloads `catalog.json` and its signature from the update location.
    func checkForUpdate(isOnline: Bool) async {
        guard let url = Self.updateURL, isOnline, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            async let document = Self.fetch(url)
            async let signature = Self.fetch(Self.signatureURL(for: url))
            try install(data: await document, signature: await signature)
        } catch CatalogVerifier.VerificationError.outdated {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            DiagnosticsLog.record(.warning, .catalog, "Catalog update failed: \(error.localizedDescription)")
        }
    }

    /// Fetches a small catalog file, bypassing caches so a new catalog is seen right away.
    private nonisolated static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4 * 1024 * 1024 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: Loading

    nonisolated static func signatureURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".sig")
    }

    /// Bundled catalog, replaced by a cached catalog only if that one verifies and is newer.
    nonisolated static func loadInitialDocument() -> CatalogDocument {
        let verifier = CatalogVerifier()
        func load(_ url: URL?) -> CatalogDocument? {
            guard let url, let data = try? Data(contentsOf: url),
                  let signature = try? Data(contentsOf: signatureURL(for: url)) else { return nil }
            return try? verifier.verifiedDocument(data: data, signature: signature)
        }
        let bundled = load(Bundle.main.url(forResource: "catalog", withExtension: "json"))
        let cached = load(AppPaths.catalogCache)
        let candidates = [bundled, cached].compactMap { $0 }
        return candidates.max { $0.catalogVersion < $1.catalogVersion } ?? .empty
    }
}

nonisolated extension JSONDecoder {
    static var catalog: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
