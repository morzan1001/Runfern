import Foundation
import Testing
@testable import Runfern

/// Verifies which Linux bases are offered: only ones this iPad can get through the catalog.
@MainActor
@Suite struct ImageLibraryTests {
    private func base(published: Bool) -> BaseImage {
        BaseImage(id: "test-\(UUID().uuidString)", distribution: "Test", release: "1", architecture: "arm64",
                  catalogVersion: 1, downloadSizeBytes: 1,
                  supportedToolchains: [],
                  source: published ? ImageSource(url: URL(string: "https://example.com/test.runfernimage")!,
                                                  sha256: String(repeating: "0", count: 64)) : nil)
    }

    @Test func plannedBasesAreNotOffered() {
        let library = ImageLibrary()
        let planned = base(published: false)

        #expect(!library.isOffered(planned))
        #expect(library.status(of: planned) == .notPublished)
        #expect(library.offered([planned, base(published: true)]).count == 1)
    }

    @Test func publishedBasesAreOffered() {
        #expect(ImageLibrary().isOffered(base(published: true)))
    }

    /// A base on the iPad works without a download, published or not.
    @Test func installedBasesAreOffered() async throws {
        let library = ImageLibrary()
        let installed = base(published: false)
        let directory = AppPaths.image(installed.id, version: installed.catalogVersion)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(library.isOffered(installed))

        try await library.remove(installed)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        #expect(!library.isOffered(installed))
    }

    /// The simulated runtime downloads nothing, so every base works there.
    @Test func simulatorOffersEveryBase() {
        #expect(ImageLibrary(offersUnpublished: true).isOffered(base(published: false)))
    }
}
