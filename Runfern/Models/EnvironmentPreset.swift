import Foundation

/// A reusable environment setup chosen by the person: Linux base, tools, VS Code extensions,
/// VS Code settings, and resources. New projects can start from it instead of choosing again.
nonisolated struct EnvironmentPreset: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var baseImageId: String
    var toolchainIds: [String]
    var extensionIds: [String]
    var resources: ResourceProfile
    /// Contents of VS Code's user `settings.json`; `nil` keeps VS Code's defaults.
    var editorSettings: String?
    /// Extensions of the tools that the preset leaves out.
    var excludedExtensionIds: [String]? = nil
    var touchOptimized: Bool? = nil

    var software: SoftwareSelection {
        get {
            SoftwareSelection(toolchainIds: toolchainIds, customExtensions: extensionIds,
                              excludedExtensions: excludedExtensionIds ?? [], touchOptimized: touchOptimized ?? false)
        }
        set {
            toolchainIds = newValue.toolchainIds
            extensionIds = newValue.customExtensions
            excludedExtensionIds = newValue.excludedExtensions
            touchOptimized = newValue.touchOptimized
        }
    }

    enum SettingsError: LocalizedError {
        case invalid

        var errorDescription: String? {
            String(localized: "The VS Code settings must be a JSON object, for example {\"editor.fontSize\": 16}.")
        }
    }

    /// Checks that `text` is a JSON object, as VS Code expects for `settings.json`.
    static func validateSettings(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)), object is [String: Any] else {
            throw SettingsError.invalid
        }
    }
}
