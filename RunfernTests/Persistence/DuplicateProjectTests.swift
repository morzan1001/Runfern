import Foundation
import Testing
@testable import Runfern

/// Verifies independent project copies (PRJ07).
@MainActor
@Suite struct DuplicateProjectTests {
    @Test(arguments: [true, false])
    func copiesAreIndependent(includeSystemState: Bool) throws {
        let store = ProjectStore(fileURL: URL.temporaryDirectory.appending(path: "store-\(UUID().uuidString).json"))
        let image = try #require(Catalog.baseImages.first)
        let original = try store.createProject(name: "Original", details: "", source: .empty, baseImage: image,
                                               toolchains: [], binding: .appInternal())
        for step in ProvisioningStep.allCases { store.markCompleted(step, for: original.environmentId) }
        let originalFiles = AppPaths.workingCopy(original.workspaceBindingId)
        try FileManager.default.createDirectory(at: originalFiles, withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: originalFiles.appending(path: "a.txt"))
        defer { store.remove(original) }

        let copy = try store.duplicate(original, name: "Copy", includeSystemState: includeSystemState)
        defer { store.remove(copy) }
        let copyFiles = AppPaths.workingCopy(copy.workspaceBindingId)
        try Data("v2".utf8).write(to: copyFiles.appending(path: "a.txt"))

        #expect(copy.id != original.id)
        #expect(copy.environmentId != original.environmentId)
        #expect(copy.workspaceBindingId != original.workspaceBindingId)
        #expect(store.binding(for: copy)?.storageMode == .appInternal)
        #expect(try String(contentsOf: originalFiles.appending(path: "a.txt"), encoding: .utf8) == "v1")
        #expect(store.environment(for: copy)?.isFullyProvisioned == includeSystemState)
    }
}
