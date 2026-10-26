import Foundation

/// State of a file or folder at a point in time.
nonisolated struct FileRecord: Codable, Hashable, Sendable {
    var isDirectory: Bool
    var size: Int64
    var modified: Date
    var hash: String?
    var isExecutable: Bool

    /// Same content in terms of syncing; timestamps don't matter.
    static func same(_ a: FileRecord?, _ b: FileRecord?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?):
            a.isDirectory == b.isDirectory && (a.isDirectory || (a.hash == b.hash && a.isExecutable == b.isExecutable))
        default: false
        }
    }
}

nonisolated struct SyncConflict: Codable, Identifiable, Hashable, Sendable {
    enum Resolution: Sendable {
        case keepLocal      // the working copy wins and is transferred
        case keepExternal   // the version from Files is taken over
        case keepBoth       // the external version is kept as an additional file
    }

    let id: UUID
    let path: String
    let detectedAt: Date
    let local: FileRecord?
    let external: FileRecord?
    /// Saved copy of the external version in the conflicts folder; stays recoverable.
    let externalCopyName: String?

    var summary: String {
        switch (local, external) {
        case (nil, _): String(localized: "Deleted in Runfern, changed in Files")
        case (_, nil): String(localized: "Deleted in Files, changed in Runfern")
        case let (l?, e?) where l.isDirectory != e.isDirectory: String(localized: "Folder and file with the same name")
        default: String(localized: "Changed differently on both sides")
        }
    }

    var canKeepBoth: Bool { local?.isDirectory == false && external?.isDirectory == false && externalCopyName != nil }
}

/// One sync step. The journal records pending and confirmed steps.
nonisolated struct JournalEntry: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case copyToLocal, copyToExternal, deleteLocal, deleteExternal, createLocalDirectory, createExternalDirectory
    }
    enum Phase: String, Codable, Sendable { case pending, done, failed }

    let operation: Operation
    let path: String
    var phase: Phase = .pending
    var error: String?
}

/// Persistent sync state of a workspace binding (SyncJournal in the data model).
nonisolated struct SyncState: Codable, Sendable {
    var baseline: [String: FileRecord] = [:]
    var localCache: [String: FileRecord] = [:]
    var externalCache: [String: FileRecord] = [:]
    var journal: [JournalEntry] = []
    var conflicts: [SyncConflict] = []
    var unsupported: [String] = []
    /// Evicted cloud files waiting for download. Optional so older saved states still decode.
    var pendingDownloads: [String]?
    var lastCompletedAt: Date?
    /// Set while steps are being applied. Remains set after an interruption (DAT04).
    var applyInProgress = false

    static func load(from url: URL) -> SyncState {
        guard let data = try? Data(contentsOf: url) else { return SyncState() }
        return (try? JSONDecoder().decode(SyncState.self, from: data)) ?? SyncState()
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Applies a conflict decision to the baseline; the next run transfers the result.
    mutating func resolve(_ conflict: SyncConflict, with resolution: SyncConflict.Resolution) {
        conflicts.removeAll { $0.id == conflict.id }
        // Setting the baseline to the other side makes only the chosen side count as changed.
        let newBaseline = resolution == .keepExternal ? conflict.local : conflict.external
        baseline[conflict.path] = newBaseline
    }
}

nonisolated struct SyncReport: Sendable {
    var pendingDownloads = 0
    var pulled = 0
    var pushed = 0
    var deleted = 0
    var newConflicts = 0
    var failures: [String] = []
}

nonisolated enum SyncError: LocalizedError {
    case listingFailed(String)
    case changedDuringSync(String)

    var errorDescription: String? {
        switch self {
        case .listingFailed(let reason): String(localized: "The folder could not be read completely: \(reason)")
        case .changedDuringSync(let path): String(localized: "“\(path)” was changed during the sync.")
        }
    }
}
