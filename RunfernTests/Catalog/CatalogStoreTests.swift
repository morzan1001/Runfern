import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Runfern

/// Verifies signed catalog handling (Plan 4.2, IMG01/IMG02).
@Suite struct CatalogStoreTests {
    let key = Curve25519.Signing.PrivateKey()
    var verifier: CatalogVerifier { CatalogVerifier(publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()) }

    private func signedCatalog(version: Int) throws -> (data: Data, signature: Data) {
        var document = activeCatalog.withLock { $0 }
        document.catalogVersion = version
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        return (data, Data(try key.signature(for: data).base64EncodedString().utf8))
    }

    @Test func bundledCatalogIsSignedByThePublisher() throws {
        let url = try #require(Bundle.main.url(forResource: "catalog", withExtension: "json"))
        let document = try CatalogVerifier().verifiedDocument(
            data: Data(contentsOf: url), signature: Data(contentsOf: CatalogStore.signatureURL(for: url)))

        #expect(document.catalogVersion >= 1)
        #expect(!document.baseImages.isEmpty)
        #expect(Catalog.toolchain(id: "python-3") != nil)
    }

    @Test func updatesComeFromTheRepositoryOverHTTPS() throws {
        let url = try #require(CatalogStore.updateURL)
        #expect(url.scheme == "https")
        #expect(url.absoluteString == "https://raw.githubusercontent.com/morzan1001/Runfern/main/Catalog/catalog.json")
        #expect(CatalogStore.signatureURL(for: url).lastPathComponent == "catalog.json.sig")
    }

    /// Everything the app downloads on the catalog's word must be pinned to HTTPS and a checksum.
    @Test func bundledCatalogPinsEveryDownload() throws {
        let document = activeCatalog.withLock { $0 }
        for image in document.baseImages {
            guard let source = image.source else { continue }
            #expect(source.url.scheme == "https")
            #expect(source.sha256.count == 64)
        }
        for package in document.toolchains.flatMap(\.packages) {
            #expect(package.url.scheme == "https")
            #expect(package.sha256.count == 64)
        }
    }

    @Test func tamperedCatalogIsRejected() throws {
        var (data, signature) = try signedCatalog(version: 99)
        data.append(contentsOf: Array(" ".utf8))

        #expect(throws: CatalogVerifier.VerificationError.self) {
            try verifier.verifiedDocument(data: data, signature: signature)
        }
    }

    @Test func olderCatalogNeverReplacesTheActiveOne() throws {
        let cache = URL.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString).json")
        let store = CatalogStore(verifier: verifier, cacheURL: cache)
        let (data, signature) = try signedCatalog(version: 0)

        #expect(throws: CatalogVerifier.VerificationError.self) {
            try store.install(data: data, signature: signature)
        }
        #expect(!FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)))
    }
}
