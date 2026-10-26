import Foundation
import Observation
import Security

/// A stored Git credential. Only metadata is held in memory; the secret stays in the keychain.
nonisolated struct Credential: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var host: String
    var username: String
    var updatedAt: Date
}

/// Manages Git credentials in the device keychain (SET05, Plan 4.8).
/// Items are device-only and never part of recipes, exports, or diagnostics.
@Observable
final class CredentialStore {
    enum CredentialError: LocalizedError {
        case invalidInput
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidInput:
                String(localized: "Enter a host, a user name, and a token.")
            case .keychain(let status):
                String(localized: "The keychain reported an error (\(Int(status))).")
            }
        }
    }

    private(set) var credentials: [Credential] = []
    private let service: String

    init(service: String = "nrw.cyber.runfern.git") {
        self.service = service
        reload()
    }

    /// Adds a credential or replaces the secret of an existing host and user combination.
    func save(host: String, username: String, secret: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !username.isEmpty, !secret.isEmpty else { throw CredentialError.invalidInput }

        let existing = credentials.first { $0.host == host && $0.username == username }
        let credential = Credential(id: existing?.id ?? UUID(), host: host, username: username, updatedAt: .now)
        let metadata = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrGeneric as String: metadata,
            kSecAttrLabel as String: "Runfern Git: \(host)",
        ]
        if existing != nil {
            try check(SecItemUpdate(query(for: credential.id) as CFDictionary, attributes as CFDictionary))
        } else {
            var item = query(for: credential.id)
            item.merge(attributes) { $1 }
            // Device-only: not synced via iCloud Keychain and not restored to other devices.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrSynchronizable as String] = false
            try check(SecItemAdd(item as CFDictionary, nil))
        }
        reload()
    }

    func remove(_ credential: Credential) throws {
        let status = SecItemDelete(query(for: credential.id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
        reload()
    }

    /// Secret for a host, read only when a remote Git action explicitly needs it.
    func secret(for credential: Credential) -> String? {
        var item = query(for: credential.id)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func reload() {
        let search: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            credentials = []
            return
        }
        credentials = items
            .compactMap { ($0[kSecAttrGeneric as String] as? Data).flatMap { try? JSONDecoder().decode(Credential.self, from: $0) } }
            .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    // MARK: Private

    private func query(for id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }
}
