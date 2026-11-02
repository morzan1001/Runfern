import BackgroundTasks
import Foundation

/// Lets explicitly started, finite work continue when the app moves to the background (R08, Plan 4.6).
/// iPadOS shows progress in a Live Activity and may still stop the work at any time, so every caller
/// must be resumable. Runfern never promises unlimited background runtime.
@MainActor
final class ContinuedWork {
    static let shared = ContinuedWork()
    /// Matches the wildcard entry in `BGTaskSchedulerPermittedIdentifiers`.
    static let identifierPrefix = "nrw.cyber.runfern.work."

    /// Progress reporting for one unit of work.
    final class Handle {
        fileprivate var task: BGContinuedProcessingTask?
        fileprivate var onExpiration: (() -> Void)?
        private var completed: Int64 = 0
        private var total: Int64 = 1
        private var subtitle: String?
        /// Set once the work has ended, so a task that iPadOS hands over afterwards ends at once.
        private var outcome: Bool?

        func report(completed: Int, of total: Int, subtitle: String? = nil) {
            self.completed = Int64(completed)
            self.total = Int64(max(total, 1))
            self.subtitle = subtitle ?? self.subtitle
            apply()
        }

        /// Moves the progress on by one unit, but not past the next multiple of `stage`, so iPadOS
        /// sees the work going on while it waits for something, such as the person.
        func advance(withinStagesOf stage: Int) {
            let unit = Int64(max(stage, 1))
            let stageEnd = (completed / unit + 1) * unit - 1
            completed = min(min(completed + 1, stageEnd), total)
            apply()
        }

        /// Moves the progress on every few seconds within the current stage of `stage` units, until
        /// the returned task is cancelled: iPadOS may end background work that shows no progress,
        /// for example while it waits for the person.
        func heartbeat(withinStagesOf stage: Int) -> Task<Void, Never> {
            Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        break
                    }
                    self.advance(withinStagesOf: stage)
                }
            }
        }

        fileprivate func attach(_ task: BGContinuedProcessingTask) {
            if let outcome {
                task.setTaskCompleted(success: outcome)
                return
            }
            self.task = task
            task.expirationHandler = { [weak self] in
                Task { @MainActor in self?.onExpiration?() }
            }
            apply()
        }

        fileprivate func finish(success: Bool) {
            outcome = success
            task?.setTaskCompleted(success: success)
            task = nil
        }

        private func apply() {
            guard let task else { return }
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = completed
            if let subtitle { task.updateTitle(task.title, subtitle: subtitle) }
        }
    }

    /// Runs `work` in the foreground and asks iPadOS to let it continue in the background.
    /// Must be called as a direct result of a person's action.
    func run(title: String, subtitle: String, _ work: @escaping @MainActor (Handle) async throws -> Void) async throws {
        let handle = Handle()
        let identifier = Self.identifierPrefix + UUID().uuidString
        let scheduler = BGTaskScheduler.shared
        let registered = scheduler.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated { handle.attach(task) }
        }
        if registered {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            // Only useful while the work runs now; a queued start after completion would be meaningless.
            request.strategy = .fail
            do {
                try await scheduler.submitTaskRequest(request)
            } catch {
                // Not available (for example in the simulator): the work simply runs in the foreground.
                DiagnosticsLog.record(.info, .app, "Continued processing unavailable: \(error.localizedDescription)")
            }
        }

        let workTask = Task { @MainActor in try await work(handle) }
        handle.onExpiration = {
            DiagnosticsLog.record(.warning, .app, "Continued processing ended by the system")
            workTask.cancel()
        }
        do {
            try await withTaskCancellationHandler {
                try await workTask.value
            } onCancel: {
                workTask.cancel()
            }
            handle.finish(success: true)
        } catch {
            handle.finish(success: false)
            throw error
        }
    }
}
