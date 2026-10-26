import Foundation
import Testing
@testable import Runfern

/// Verifies the storage contract of the sync engine (Plan 4.5, test scenarios T05, T07, T08).
@Suite struct WorkspaceSyncTests {
    let base = URL.temporaryDirectory.appending(path: "RunfernTests-\(UUID().uuidString)")
    var local: URL { base.appending(path: "local") }
    var external: URL { base.appending(path: "external") }
    var engine: SyncEngine { SyncEngine(localRoot: local, externalRoot: external, conflictsRoot: base.appending(path: "conflicts")) }

    init() throws {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    }

    private func write(_ root: URL, _ path: String, _ content: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func read(_ root: URL, _ path: String) -> String? {
        try? String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    @Test func importsExistingFolderAndSkipsCaches() throws {
        try write(external, "main.py", "print(1)")
        try write(external, "src/util.py", "x = 1")
        try write(external, ".git/HEAD", "ref: refs/heads/main")
        try write(external, "__pycache__/main.cpython.pyc", "bytes")
        var state = SyncState()

        let report = try engine.run(&state) { _ in }

        #expect(read(local, "main.py") == "print(1)")
        #expect(read(local, "src/util.py") == "x = 1")
        #expect(read(local, ".git/HEAD") == "ref: refs/heads/main")
        #expect(read(local, "__pycache__/main.cpython.pyc") == nil)
        #expect(report.pulled >= 3)
        #expect(SyncEngine.pendingLocalChanges(localRoot: local, state: state) == 0)
    }

    @Test func pushesLocalChangesAndPropagatesDeletions() throws {
        try write(external, "a.txt", "1")
        try write(external, "b.txt", "1")
        var state = SyncState()
        _ = try engine.run(&state) { _ in }

        try write(local, "a.txt", "2")
        try write(local, "new.txt", "new")
        #expect(SyncEngine.pendingLocalChanges(localRoot: local, state: state) == 2)
        try FileManager.default.removeItem(at: external.appending(path: "b.txt"))
        _ = try engine.run(&state) { _ in }

        #expect(read(external, "a.txt") == "2")
        #expect(read(external, "new.txt") == "new")
        #expect(read(local, "b.txt") == nil)
        #expect(state.conflicts.isEmpty)
    }

    @Test func concurrentChangesBecomeConflictAndAreNeverOverwritten() throws {
        try write(external, "a.txt", "base")
        var state = SyncState()
        _ = try engine.run(&state) { _ in }

        try write(local, "a.txt", "local")
        try write(external, "a.txt", "external")
        let report = try engine.run(&state) { _ in }
        _ = try engine.run(&state) { _ in }

        #expect(report.newConflicts == 1)
        #expect(state.conflicts.count == 1)
        #expect(read(local, "a.txt") == "local")
        #expect(read(external, "a.txt") == "external")
    }

    @Test(arguments: [SyncConflict.Resolution.keepLocal, .keepExternal, .keepBoth])
    func resolvesConflicts(_ resolution: SyncConflict.Resolution) throws {
        try write(external, "a.txt", "base")
        var state = SyncState()
        _ = try engine.run(&state) { _ in }
        try write(local, "a.txt", "local")
        try write(external, "a.txt", "external")
        _ = try engine.run(&state) { _ in }
        let conflict = try #require(state.conflicts.first)

        if resolution == .keepBoth {
            try SyncEngine.keepBoth(conflict, localRoot: local, conflictsRoot: base.appending(path: "conflicts"))
        }
        state.resolve(conflict, with: resolution)
        _ = try engine.run(&state) { _ in }

        let expected = resolution == .keepExternal ? "external" : "local"
        #expect(read(local, "a.txt") == expected)
        #expect(read(external, "a.txt") == expected)
        #expect(state.conflicts.isEmpty)
        if resolution == .keepBoth {
            // Expected names are resolved through the app bundle so the test passes in every device language.
            #expect(read(external, "a (\(String(localized: "from Files", bundle: .main))).txt") == "external")
        }
    }

    @Test func modifyVersusDeleteIsAConflict() throws {
        try write(external, "a.txt", "base")
        var state = SyncState()
        _ = try engine.run(&state) { _ in }
        try FileManager.default.removeItem(at: local.appending(path: "a.txt"))
        try write(external, "a.txt", "changed")

        _ = try engine.run(&state) { _ in }

        #expect(state.conflicts.count == 1)
        #expect(read(external, "a.txt") == "changed")
    }

    @Test func unreachableFolderKeepsLocalDataAndDeletesNothing() throws {
        try write(external, "a.txt", "1")
        var state = SyncState()
        _ = try engine.run(&state) { _ in }
        try write(local, "a.txt", "2")
        try FileManager.default.removeItem(at: external)

        #expect(throws: SyncError.self) { try engine.run(&state) { _ in } }
        #expect(read(local, "a.txt") == "2")
        #expect(SyncEngine.pendingLocalChanges(localRoot: local, state: state) == 1)
    }

    @Test func interruptedRunIsCompletedWithoutDuplicates() throws {
        try write(external, "a.txt", "1")
        try write(external, "b.txt", "1")
        var state = SyncState()
        // Simulates an interruption after the first step: the file is already local, the baseline is still missing.
        try write(local, "a.txt", "1")
        state.applyInProgress = true

        _ = try engine.run(&state) { _ in }

        #expect(state.conflicts.isEmpty)
        #expect(state.applyInProgress == false)
        #expect(read(local, "b.txt") == "1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: local.path(percentEncoded: false)).sorted() == ["a.txt", "b.txt"])
    }

    @Test func symbolicLinksAreReportedNotFollowed() throws {
        try write(external, "a.txt", "1")
        try FileManager.default.createSymbolicLink(at: external.appending(path: "link"), withDestinationURL: external.appending(path: "a.txt"))
        var state = SyncState()

        _ = try engine.run(&state) { _ in }

        #expect(state.unsupported == [String(localized: "Files: \("link")", bundle: .main)])
        #expect(!FileManager.default.fileExists(atPath: local.appending(path: "link").path(percentEncoded: false)))
    }

    @Test func evictedCloudFileIsNeverTreatedAsDeleted() throws {
        try write(external, "src/a.txt", "1")
        var state = SyncState()
        _ = try engine.run(&state) { _ in }

        // iPadOS evicts the file and leaves a placeholder; local edits in the meantime must survive.
        try FileManager.default.removeItem(at: external.appending(path: "src/a.txt"))
        try write(external, "src/.a.txt.icloud", "placeholder")
        try write(local, "src/a.txt", "2")
        let report = try engine.run(&state) { _ in }

        #expect(read(local, "src/a.txt") == "2")
        #expect(report.pendingDownloads == 1)
        #expect(state.pendingDownloads == ["src/a.txt"])
        #expect(state.conflicts.isEmpty)
        #expect(read(local, "src/.a.txt.icloud") == nil)
    }

    @Test func placeholderNamesMapToOriginalFiles() {
        #expect(DirectoryScanner.placeholderTarget(of: ".main.py.icloud") == "main.py")
        #expect(DirectoryScanner.placeholderTarget(of: "main.py") == nil)
        #expect(DirectoryScanner.placeholderTarget(of: "..icloud") == nil)
    }
}
