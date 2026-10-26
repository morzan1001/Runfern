import Foundation
import Testing
@testable import Runfern

/// Verifies keychain-backed credential management (SET05).
@Suite struct CredentialStoreTests {
    /// Each test uses its own keychain service so real entries are never touched.
    private func makeStore() -> CredentialStore {
        CredentialStore(service: "nrw.cyber.runfern.tests.\(UUID().uuidString)")
    }

    private func removeAll(in store: CredentialStore) {
        store.credentials.forEach { try? store.remove($0) }
    }

    @Test func savesListsAndReadsSecrets() throws {
        let store = makeStore()
        defer { removeAll(in: store) }

        try store.save(host: " GitHub.com ", username: "octo", secret: "token-1")

        let credential = try #require(store.credentials.first)
        #expect(credential.host == "github.com")
        #expect(store.secret(for: credential) == "token-1")
    }

    @Test func replacingKeepsIdentityAndUpdatesSecret() throws {
        let store = makeStore()
        defer { removeAll(in: store) }
        try store.save(host: "github.com", username: "octo", secret: "old")
        let original = try #require(store.credentials.first)

        try store.save(host: "github.com", username: "octo", secret: "new")

        #expect(store.credentials.count == 1)
        #expect(store.credentials.first?.id == original.id)
        #expect(store.secret(for: original) == "new")
    }

    @Test func removedCredentialsAreGone() throws {
        let store = makeStore()
        try store.save(host: "gitlab.com", username: "dev", secret: "s")
        let credential = try #require(store.credentials.first)

        try store.remove(credential)

        #expect(store.credentials.isEmpty)
        #expect(store.secret(for: credential) == nil)
    }

    @Test func incompleteInputIsRejected() {
        let store = makeStore()

        #expect(throws: CredentialStore.CredentialError.self) {
            try store.save(host: "github.com", username: "", secret: "s")
        }
    }
}
