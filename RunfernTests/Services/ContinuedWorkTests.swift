import Foundation
import Testing
@testable import Runfern

/// Verifies that continued work behaves like plain foreground work when iPadOS doesn't run it (R08).
@MainActor
@Suite struct ContinuedWorkTests {
    struct Failure: Error, Equatable {}

    @Test func runsWorkAndReportsProgress() async throws {
        var steps: [Int] = []

        try await ContinuedWork.shared.run(title: "Test", subtitle: "Step") { handle in
            for step in 1...3 {
                handle.report(completed: step, of: 3)
                steps.append(step)
            }
        }

        #expect(steps == [1, 2, 3])
    }

    @Test func propagatesErrors() async {
        await #expect(throws: Failure()) {
            try await ContinuedWork.shared.run(title: "Test", subtitle: "Step") { _ in throw Failure() }
        }
    }

    @Test func cancellingTheCallerCancelsTheWork() async throws {
        let outer = Task { @MainActor in
            try await ContinuedWork.shared.run(title: "Test", subtitle: "Step") { _ in
                try await Task.sleep(for: .seconds(30))
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        outer.cancel()

        await #expect(throws: CancellationError.self) { try await outer.value }
    }
}
