import Foundation

// Sync between the local working copy and the selected folder in Files (Plan 4.3–4.5, FIL04/FIL06).
//
// It is a three-way comparison: for every path the common baseline, the local working copy, and the
// external folder are compared. Only a one-sided change is transferred; different changes on both
// sides become a conflict and are never overwritten silently.
// A run is idempotent: after an interruption the next run recognizes already transferred files as
// equal, and the baseline only advances once the transfer has completed.

nonisolated struct SyncEngine {
    let localRoot: URL
    let externalRoot: URL
    let conflictsRoot: URL

    private let fm = FileManager.default
    private let coordinator = NSFileCoordinator()

    /// Performs a full sync. `persist` saves the journal durably along the way.
    func run(_ state: inout SyncState, persist: (SyncState) -> Void) throws -> SyncReport {
        try fm.createDirectory(at: localRoot, withIntermediateDirectories: true)
        let local = try DirectoryScanner.scan(localRoot, cache: state.localCache)
        let external = try coordinatedRead(externalRoot) { try DirectoryScanner.scan($0, cache: state.externalCache) }
        state.localCache = local.records
        state.externalCache = external.records
        state.unsupported = (local.unsupported.map { "Runfern: \($0)" } + external.unsupported.map { String(localized: "Files: \($0)") })
        state.pendingDownloads = external.pending.sorted()

        var report = SyncReport()
        report.pendingDownloads = external.pending.count
        // Evicted cloud files are neither deleted nor changed; they wait until the provider delivers them.
        var blocked = Set(state.conflicts.map(\.path)).union(external.pending)
        var operations: [JournalEntry] = []
        let paths = Set(state.baseline.keys).union(local.records.keys).union(external.records.keys).sorted()

        for path in paths where !isBlocked(path, by: blocked) {
            let base = state.baseline[path], l = local.records[path], e = external.records[path]
            if FileRecord.same(l, e) { continue }
            let localChanged = !FileRecord.same(l, base)
            let externalChanged = !FileRecord.same(e, base)
            // Switching between file and folder would delete the other side's content when replacing.
            let kinds = Set([base, l, e].compactMap { $0?.isDirectory })

            if kinds.count == 1, localChanged, !externalChanged {
                let operation: JournalEntry.Operation = l.map { $0.isDirectory ? .createExternalDirectory : .copyToExternal } ?? .deleteExternal
                operations.append(JournalEntry(operation: operation, path: path))
            } else if kinds.count == 1, externalChanged, !localChanged {
                let operation: JournalEntry.Operation = e.map { $0.isDirectory ? .createLocalDirectory : .copyToLocal } ?? .deleteLocal
                operations.append(JournalEntry(operation: operation, path: path))
            } else {
                state.conflicts.append(makeConflict(path: path, local: l, external: e))
                blocked.insert(path)
                report.newConflicts += 1
            }
        }

        // Create folders first, delete last and from the inside out.
        operations.sort { order($0) != order($1) ? order($0) < order($1) : ($0.operation.isDeletion ? $0.path > $1.path : $0.path < $1.path) }

        state.journal = operations
        state.applyInProgress = true
        persist(state)

        for index in state.journal.indices {
            let entry = state.journal[index]
            do {
                try apply(entry, expectedLocal: local.records[entry.path], expectedExternal: external.records[entry.path])
                state.journal[index].phase = .done
                switch entry.operation {
                case .copyToLocal, .createLocalDirectory: report.pulled += 1
                case .copyToExternal, .createExternalDirectory: report.pushed += 1
                case .deleteLocal, .deleteExternal: report.deleted += 1
                }
            } catch {
                state.journal[index].phase = .failed
                state.journal[index].error = error.localizedDescription
                report.failures.append("\(entry.path): \(error.localizedDescription)")
            }
            if index % 50 == 49 { persist(state) }
        }

        // New baseline: only paths that match on both sides after the run.
        let localAfter = try DirectoryScanner.scan(localRoot, cache: state.localCache).records
        let externalAfter = try coordinatedRead(externalRoot) { try DirectoryScanner.scan($0, cache: state.externalCache) }.records
        for path in Set(state.baseline.keys).union(localAfter.keys).union(externalAfter.keys) {
            let l = localAfter[path], e = externalAfter[path]
            if FileRecord.same(l, e) { state.baseline[path] = l }
        }
        // Conflicts that have since been resolved identically on both sides are done.
        state.conflicts.removeAll { FileRecord.same(localAfter[$0.path], externalAfter[$0.path]) }
        state.localCache = localAfter
        state.externalCache = externalAfter
        state.journal.removeAll { $0.phase == .done }
        state.applyInProgress = false
        state.lastCompletedAt = .now
        persist(state)
        return report
    }

    /// Keeps the external version as an additional file next to the local one (conflict resolution “keep both”).
    static func keepBoth(_ conflict: SyncConflict, localRoot: URL, conflictsRoot: URL) throws {
        guard let copyName = conflict.externalCopyName else { return }
        let target = localRoot.appending(path: alternateName(for: conflict.path, in: localRoot, label: String(localized: "from Files")))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: conflictsRoot.appending(path: copyName), to: target)
    }

    /// Local changes not yet transferred to the selected folder.
    static func pendingLocalChanges(localRoot: URL, state: SyncState) -> Int {
        guard let local = try? DirectoryScanner.scan(localRoot, cache: state.localCache) else { return 0 }
        let paths = Set(state.baseline.keys).union(local.records.keys)
        return paths.filter { !FileRecord.same(local.records[$0], state.baseline[$0]) }.count
    }

    // MARK: Private

    private func isBlocked(_ path: String, by blocked: Set<String>) -> Bool {
        blocked.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func order(_ entry: JournalEntry) -> Int {
        switch entry.operation {
        case .createLocalDirectory, .createExternalDirectory: 0
        case .copyToLocal, .copyToExternal: 1
        case .deleteLocal, .deleteExternal: 2
        }
    }

    private func makeConflict(path: String, local: FileRecord?, external: FileRecord?) -> SyncConflict {
        var copyName: String?
        if external?.isDirectory == false {
            let name = "\(UUID().uuidString)-\((path as NSString).lastPathComponent)"
            let source = externalRoot.appending(path: path)
            try? fm.createDirectory(at: conflictsRoot, withIntermediateDirectories: true)
            if (try? coordinatedRead(source) { try fm.copyItem(at: $0, to: conflictsRoot.appending(path: name)) }) != nil {
                copyName = name
            }
        }
        return SyncConflict(id: UUID(), path: path, detectedAt: .now, local: local, external: external, externalCopyName: copyName)
    }

    private func apply(_ entry: JournalEntry, expectedLocal: FileRecord?, expectedExternal: FileRecord?) throws {
        let localURL = localRoot.appending(path: entry.path)
        let externalURL = externalRoot.appending(path: entry.path)

        switch entry.operation {
        case .createLocalDirectory:
            try fm.createDirectory(at: localURL, withIntermediateDirectories: true)
        case .createExternalDirectory:
            try coordinatedWrite(externalURL, options: []) { try fm.createDirectory(at: $0, withIntermediateDirectories: true) }
        case .copyToLocal:
            try ensureUnchanged(localURL, expected: expectedLocal, path: entry.path)
            try coordinatedRead(externalURL) { try atomicCopy(from: $0, to: localURL) }
        case .copyToExternal:
            try coordinatedWrite(externalURL, options: .forReplacing) { target in
                try ensureUnchanged(target, expected: expectedExternal, path: entry.path)
                try atomicCopy(from: localURL, to: target)
            }
        case .deleteLocal:
            try ensureUnchanged(localURL, expected: expectedLocal, path: entry.path)
            try remove(localURL)
        case .deleteExternal:
            try coordinatedWrite(externalURL, options: .forDeleting) { target in
                try ensureUnchanged(target, expected: expectedExternal, path: entry.path)
                try remove(target)
            }
        }
    }

    /// Guards against changes between scanning and writing; the next run decides again.
    private func ensureUnchanged(_ url: URL, expected: FileRecord?, path: String) throws {
        let current = try DirectoryScanner.record(at: url)
        // Folders are only checked for existence; their content is synced path by path.
        if current?.isDirectory == true, expected?.isDirectory == true { return }
        guard FileRecord.same(current, expected) else { throw SyncError.changedDuringSync(path) }
    }

    /// Writes to a temporary target in the same folder, then replaces atomically.
    private func atomicCopy(from source: URL, to target: URL) throws {
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appending(path: DirectoryScanner.temporaryPrefix + UUID().uuidString)
        try fm.copyItem(at: source, to: temporary)
        do {
            if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                _ = try fm.replaceItemAt(target, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: target)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// Folders are only removed when empty; otherwise they contain changes from the other side.
    private func remove(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            let contents = try fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))
            guard contents.allSatisfy(DirectoryScanner.isExcluded) else { return }
        }
        try fm.removeItem(at: url)
    }

    private func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Swift.Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { url in
            result = Swift.Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SyncError.listingFailed(String(localized: "File coordination failed")) }
        return try result.get()
    }

    private func coordinatedWrite(_ url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var innerError: Error?
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            do { try body(url) } catch { innerError = error }
        }
        if let coordinationError { throw coordinationError }
        if let innerError { throw innerError }
    }

    /// A free name next to `path`, such as “main (from Files).py”.
    static func alternateName(for path: String, in root: URL, label: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let file = (path as NSString).lastPathComponent
        let stem = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        var counter = 1
        while true {
            let suffix = counter == 1 ? " (\(label))" : " (\(label) \(counter))"
            let name = ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)"
            let candidate = directory.isEmpty ? name : "\(directory)/\(name)"
            if !FileManager.default.fileExists(atPath: root.appending(path: candidate).path(percentEncoded: false)) {
                return candidate
            }
            counter += 1
        }
    }
}

private nonisolated extension JournalEntry.Operation {
    var isDeletion: Bool { self == .deleteLocal || self == .deleteExternal }
}
