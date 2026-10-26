import Foundation

/// Initial content of a new project (NEW02/NEW03).
nonisolated enum ProjectSource: String, Codable, CaseIterable, Sendable {
    case empty
    case pythonStarter
    case existingFolder

    var title: String {
        switch self {
        case .empty: String(localized: "Empty Project")
        case .pythonStarter: String(localized: "Python Starter Template")
        case .existingFolder: String(localized: "Existing Folder")
        }
    }
}

nonisolated struct Project: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var details: String
    let environmentId: UUID
    let workspaceBindingId: UUID
    let createdAt: Date
    var lastOpenedAt: Date?
    var isArchived: Bool
    var source: ProjectSource?
}

/// The complete persistent inventory; written atomically as a single file.
nonisolated struct StoreSnapshot: Codable, Sendable {
    var version = 1
    var projects: [Project] = []
    var environments: [DevEnvironment] = []
    var bindings: [WorkspaceBinding] = []
    /// Optional because stores written before presets existed lack the key.
    var presets: [EnvironmentPreset]?
}
