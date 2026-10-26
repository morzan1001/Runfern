import Synchronization

/// How the QEMU instance ended, once it has.
nonisolated final class QEMUExit: Sendable {
    private let outcome = Mutex<Result<Int32, QEMULauncher.LaunchError>?>(nil)

    var result: Result<Int32, QEMULauncher.LaunchError>? { outcome.withLock { $0 } }

    func record(_ result: Result<Int32, QEMULauncher.LaunchError>) {
        outcome.withLock { $0 = result }
    }

    /// Waits until QEMU has exited or the timeout passes; `nil` means it is still running.
    func wait(timeout: Duration) async -> Result<Int32, QEMULauncher.LaunchError>? {
        let deadline = ContinuousClock.now + timeout
        while result == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return result
    }
}
