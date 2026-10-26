import Synchronization

/// Waits for a task that must run to completion, for example a VM boot or an installation inside
/// the guest, while letting the waiting caller give up at once when it is canceled. The task itself
/// keeps running; a later caller can pick up its result.
nonisolated func awaitDetached<Value: Sendable>(_ task: Task<Value, Error>) async throws -> Value {
    let once = ResumeOnce<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            Task { once.resume(with: await task.result) }
        }
    } onCancel: {
        once.resume(with: .failure(CancellationError()))
    }
}

/// Resumes a continuation exactly once, whichever of result or cancellation comes first.
private nonisolated final class ResumeOnce<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var early: Result<Value, Error>?
        var done = false
    }

    private let state = Mutex(State())

    func set(_ continuation: CheckedContinuation<Value, Error>) {
        let early: Result<Value, Error>? = state.withLock { state in
            if let early = state.early { state.done = true; return early }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func resume(with result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = state.withLock { state in
            guard !state.done else { return nil }
            guard let continuation = state.continuation else {
                if state.early == nil { state.early = result }
                return nil
            }
            state.done = true
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
