import Foundation
import Testing
@testable import Runfern

/// Verifies session-bound development server previews (IDE09).
@MainActor
@Suite struct DevServerPreviewTests {
    private func runningProject() async throws -> (RuntimeCoordinator, ProjectStore, Project) {
        let store = ProjectStore(fileURL: URL.temporaryDirectory.appending(path: "store-\(UUID().uuidString).json"))
        let project = try store.createProject(name: "Web", details: "", source: .empty, baseImage: try #require(Catalog.baseImages.first),
                                              toolchains: [], binding: .appInternal())
        for step in ProvisioningStep.allCases { store.markCompleted(step, for: project.environmentId) }
        store.setState(.ready, for: project.environmentId)
        let runtime = RuntimeCoordinator(store: store, sync: SyncCenter(), adapter: SimulatedEmulatorAdapter())
        await runtime.open(project)
        return (runtime, store, project)
    }

    @Test func forwardedPortsBelongToTheSession() async throws {
        let (runtime, store, project) = try await runningProject()
        defer { store.remove(project) }

        let url = try await runtime.preview(port: 3000)

        #expect(url.host() == "127.0.0.1")
        #expect(runtime.session?.previewPorts[3000] == url.port)

        await runtime.stopActiveProject()
        #expect(runtime.session == nil)
        await #expect(throws: RuntimeCoordinator.PreviewError.notRunning) { try await runtime.preview(port: 3000) }
    }

    @Test(arguments: [80, 8080, 70_000])
    func reservedAndInvalidPortsAreRejected(port: Int) async throws {
        let (runtime, store, project) = try await runningProject()
        defer { store.remove(project) }

        await #expect(throws: RuntimeCoordinator.PreviewError.invalidPort) { try await runtime.preview(port: port) }
        await runtime.stopActiveProject()
    }
}
