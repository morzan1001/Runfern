import Foundation

/// Reachability of the selected project folder.
nonisolated enum AccessState: String, Codable, Sendable {
    case granted
    case stale          // bookmark is outdated but still resolvable
    case unavailable    // folder moved, volume missing, or access revoked
}

nonisolated enum StorageMode: String, Codable, Sendable {
    case localFolder    // cloud folder in Files with a local working copy and sync
    case mountedFolder  // folder on the device or a drive, mounted directly into Linux
    case appInternal    // working copy only inside the app (sample project)
}

/// Link between a project and its storage location (WorkspaceBinding).
nonisolated struct WorkspaceBinding: Identifiable, Codable, Sendable {
    let id: UUID
    var storageMode: StorageMode
    var bookmark: Data?
    var displayPath: String
    /// Resolved, normalized path; used to detect duplicate or overlapping registrations.
    var workspaceIdentity: String
    var accessState: AccessState

    /// The folder was chosen in Files, either mounted directly or synced.
    var isInFiles: Bool { storageMode != .appInternal }

    /// Location shown in the UI. App-internal storage is localized at display time, not when stored.
    var displayLocation: String {
        storageMode == .appInternal ? String(localized: "In Runfern") : displayPath
    }

    static func appInternal() -> WorkspaceBinding {
        let id = UUID()
        return WorkspaceBinding(id: id, storageMode: .appInternal, bookmark: nil,
                                displayPath: "", workspaceIdentity: "internal:\(id)", accessState: .granted)
    }
}
