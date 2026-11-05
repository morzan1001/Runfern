import Foundation
import Observation

/// Drives the sync runs of all projects and exposes their state to the UI.
/// Runs for the same binding are serialized; there are never two competing writers.
@Observable
final class SyncCenter {
    struct Status {
        enum Phase: Equatable {
            case idle
            case syncing
            case unreachable(String)
            case failed(String)
        }

        var phase: Phase = .idle
        var lastSyncedAt: Date?
        /// Locally saved changes that have not reached the selected folder yet.
        var pendingLocalChanges = 0
        var conflicts: [SyncConflict] = []
        var unsupported: [String] = []
        /// Cloud files that exist in the folder but are still downloading.
        var pendingDownloads = 0
        var failures: [String] = []
        /// An earlier run was interrupted and continues with the next sync.
        var wasInterrupted = false

        var hasUnsyncedData: Bool { pendingLocalChanges > 0 || !conflicts.isEmpty }
    }

    private(set) var statuses: [UUID: Status] = [:]
    /// Stored sync state is read once per launch, off the main thread (`load(_:)`).
    /// Until then `status(for:)` knows nothing, so callers that warn about data loss stay cautious.
    private(set) var hasLoaded = false
    private var inFlight: [UUID: Task<Bool, Never>] = [:]

    func status(for binding: WorkspaceBinding) -> Status {
        statuses[binding.id] ?? Status()
    }

    /// Loads the stored state of all bindings, e.g. to detect interrupted runs. Decoding the journals
    /// and scanning the working copies runs detached, so launch never waits for it.
    func load(_ bindings: [WorkspaceBinding]) async {
        let synced = bindings.filter { $0.storageMode == .localFolder }
        let loaded = await Task.detached(priority: .utility) {
            synced.map { b -> (UUID, SyncState, Int) in
                let state = SyncState.load(from: AppPaths.syncState(b.id))
                return (b.id, state, SyncEngine.pendingLocalChanges(localRoot: AppPaths.workingCopy(b.id), state: state))
            }
        }.value
        for (id, state, pending) in loaded where statuses[id] == nil {   // A sync that already started wins.
            var status = Status()
            status.lastSyncedAt = state.lastCompletedAt
            status.conflicts = state.conflicts
            status.unsupported = state.unsupported
            status.pendingDownloads = state.pendingDownloads?.count ?? 0
            status.wasInterrupted = state.applyInProgress
            status.pendingLocalChanges = pending
            statuses[id] = status
        }
        hasLoaded = true
    }

    /// Syncs and returns `true` if the selected folder matches the local state afterwards.
    @discardableResult
    func sync(_ binding: WorkspaceBinding) async -> Bool {
        guard binding.storageMode == .localFolder else { return true }
        let previous = inFlight[binding.id]
        let task = Task<Bool, Never> {
            _ = await previous?.value
            return await perform(binding)
        }
        inFlight[binding.id] = task
        let result = await task.value
        if inFlight[binding.id] == task { inFlight[binding.id] = nil }
        return result
    }

    func resolve(_ conflict: SyncConflict, with resolution: SyncConflict.Resolution, in binding: WorkspaceBinding) async {
        let id = binding.id
        let outcome = await Task.detached(priority: .userInitiated) { () -> String? in
            var state = SyncState.load(from: AppPaths.syncState(id))
            do {
                if resolution == .keepBoth {
                    try SyncEngine.keepBoth(conflict, localRoot: AppPaths.workingCopy(id), conflictsRoot: AppPaths.conflicts(id))
                }
                state.resolve(conflict, with: resolution)
                try state.save(to: AppPaths.syncState(id))
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let outcome {
            statuses[id, default: Status()].phase = .failed(outcome)
            return
        }
        await sync(binding)
    }

    /// The binding is gone; its files are removed with the project (`ProjectStore.remove`).
    func forgetStatus(for bindingID: UUID) { statuses[bindingID] = nil }

    // MARK: Private

    private func perform(_ binding: WorkspaceBinding) async -> Bool {
        statuses[binding.id, default: Status()].phase = .syncing
        let outcome = await Task.detached(priority: .utility) { () -> (SyncState, Result<SyncReport, Error>) in
            let id = binding.id
            var state = SyncState.load(from: AppPaths.syncState(id))
            do {
                let external = try WorkspaceAccess.resolve(binding)
                let didStart = external.startAccessingSecurityScopedResource()
                defer { if didStart { external.stopAccessingSecurityScopedResource() } }
                let engine = SyncEngine(localRoot: AppPaths.workingCopy(id), externalRoot: external,
                                        conflictsRoot: AppPaths.conflicts(id))
                let report = try engine.run(&state) { try? $0.save(to: AppPaths.syncState(id)) }
                return (state, .success(report))
            } catch {
                try? state.save(to: AppPaths.syncState(id))
                return (state, .failure(error))
            }
        }.value

        let (state, result) = outcome
        var status = statuses[binding.id] ?? Status()
        status.conflicts = state.conflicts
        status.unsupported = state.unsupported
        status.pendingDownloads = state.pendingDownloads?.count ?? 0
        status.lastSyncedAt = state.lastCompletedAt
        status.wasInterrupted = state.applyInProgress
        status.pendingLocalChanges = await Task.detached {
            SyncEngine.pendingLocalChanges(localRoot: AppPaths.workingCopy(binding.id), state: state)
        }.value

        let isCurrent: Bool
        switch result {
        case .success(let report):
            status.failures = report.failures
            status.phase = report.failures.isEmpty ? .idle : .failed(String(localized: "\(report.failures.count) files could not be transferred."))
            isCurrent = report.failures.isEmpty && state.conflicts.isEmpty
        case .failure(let error as WorkspaceAccess.AccessError):
            status.phase = .unreachable(error.localizedDescription)
            isCurrent = false
        case .failure(let error as SyncError):
            status.phase = .unreachable(error.localizedDescription)
            isCurrent = false
        case .failure(let error):
            status.phase = .failed(error.localizedDescription)
            DiagnosticsLog.record(.error, .sync, "Sync failed: \(error.localizedDescription)")
            isCurrent = false
        }
        statuses[binding.id] = status
        return isCurrent
    }
}
