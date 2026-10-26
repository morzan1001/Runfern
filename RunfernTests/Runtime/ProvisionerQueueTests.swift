import Foundation
import Testing
@testable import Runfern

/// Setups of several projects share the one VM, so they run one after the other.
@MainActor
@Suite struct ProvisionerQueueTests {
    let store = ProjectStore(fileURL: URL.temporaryDirectory.appending(path: "queue-\(UUID().uuidString).json"))
    let provisioner: Provisioner

    init() {
        provisioner = Provisioner(store: store, images: ImageLibrary(), sync: SyncCenter(), connectivity: Connectivity())
    }

    private func makeProject(_ name: String) throws -> Project {
        try store.createProject(name: name, details: "", source: .empty, baseImage: Catalog.baseImages[0],
                                toolchains: [], binding: .appInternal())
    }

    private func waitUntilIdle(_ projects: [Project]) async throws {
        for _ in 0..<600 where projects.contains(where: provisioner.isRunning) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func secondSetupWaitsForTheFirst() async throws {
        let first = try makeProject("First")
        let second = try makeProject("Second")
        provisioner.start(first)
        provisioner.start(second)
        #expect(provisioner.waiting.contains(second.id))
        #expect(!provisioner.waiting.contains(first.id))
        #expect(provisioner.isUsingVM(otherThan: second))
        #expect(!provisioner.isUsingVM(otherThan: first))

        try await waitUntilIdle([first, second])
        #expect(store.environment(for: first)?.isFullyProvisioned == true)
        #expect(store.environment(for: second)?.isFullyProvisioned == true)
        #expect(provisioner.waiting.isEmpty)
    }

    @Test func cancelingAWaitingSetupLeavesItUntouched() async throws {
        let first = try makeProject("First")
        let second = try makeProject("Second")
        provisioner.start(first)
        provisioner.start(second)
        provisioner.cancel(second)

        try await waitUntilIdle([first, second])
        #expect(store.environment(for: first)?.isFullyProvisioned == true)
        let waitingEnvironment = try #require(store.environment(for: second))
        #expect(waitingEnvironment.completedSteps.isEmpty)
        #expect(waitingEnvironment.lastError == nil)
    }
}
