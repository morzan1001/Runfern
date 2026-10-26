import Foundation
import Synchronization
import Testing
@testable import Runfern

/// Verifies that canceling setup returns at once while the guest's work runs to completion.
@Suite struct DetachedWorkTests {
    @Test func canceledWaiterReturnsWhileWorkContinues() async throws {
        let finished = Mutex(false)
        let work = Task<Int, Error> {
            try? await Task.sleep(for: .milliseconds(400))
            finished.withLock { $0 = true }
            return 42
        }
        let waiter = Task { try await awaitDetached(work) }

        try await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(ContinuousClock.now - started < .milliseconds(200))

        // The work was not canceled and a later caller still gets its result.
        #expect(try await awaitDetached(work) == 42)
        #expect(finished.withLock { $0 })
    }

    @Test func resultIsPassedThrough() async throws {
        #expect(try await awaitDetached(Task { "ready" }) == "ready")
    }
}
