import Foundation
import Testing
@testable import Runfern

@Suite struct ProjectStoreTests {
    private func makeStore() -> ProjectStore {
        ProjectStore(fileURL: URL.temporaryDirectory.appending(path: "store-\(UUID().uuidString).json"))
    }

    private func folderBinding(_ path: String) -> WorkspaceBinding {
        WorkspaceBinding(id: UUID(), storageMode: .localFolder, bookmark: nil, displayPath: path,
                         workspaceIdentity: path, accessState: .granted)
    }

    @Test func overlappingFoldersGetOnlyOneWriteOwner() throws {
        let store = makeStore()
        let image = Catalog.baseImages[0]
        _ = try store.createProject(name: "A", details: "", source: .empty, baseImage: image,
                                    toolchains: [], binding: folderBinding("/x/projekt"))

        #expect(throws: ProjectStore.StoreError.self) {
            try store.createProject(name: "B", details: "", source: .empty, baseImage: image,
                                    toolchains: [], binding: folderBinding("/x/projekt/sub"))
        }
        #expect(throws: (any Error).self) {
            try store.createProject(name: "  ", details: "", source: .empty, baseImage: image,
                                    toolchains: [], binding: folderBinding("/y"))
        }
    }

    @Test func persistsAcrossRestartAndMarksInterruptedSessions() throws {
        let url = URL.temporaryDirectory.appending(path: "store-\(UUID().uuidString).json")
        let store = ProjectStore(fileURL: url)
        let project = try store.createProject(name: "A", details: "", source: .empty, baseImage: Catalog.baseImages[0],
                                              toolchains: [], binding: .appInternal())
        store.setState(.running, for: project.environmentId)

        let reopened = ProjectStore(fileURL: url)

        #expect(reopened.activeProjects.map(\.name) == ["A"])
        #expect(reopened.environment(for: project)?.state == .repairNeeded)
        #expect(reopened.recoveredEnvironmentIDs.contains(project.environmentId))
    }

    @Test func renameKeepsIdentity() throws {
        let store = makeStore()
        let project = try store.createProject(name: "Old", details: "", source: .empty, baseImage: Catalog.baseImages[0],
                                              toolchains: [], binding: .appInternal())
        store.rename(project, name: "New", details: "Description")

        let renamed = try #require(store.project(id: project.id))
        #expect(renamed.name == "New")
        #expect(renamed.environmentId == project.environmentId)
        #expect(renamed.workspaceBindingId == project.workspaceBindingId)
    }
}
