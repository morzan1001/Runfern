#if DEBUG
/// Timestamped console output of the on-device tests, so a hang shows exactly where it happens.
nonisolated struct TestLog: Sendable {
    let tag: String
    private let start = ContinuousClock.now

    init(_ tag: String) {
        self.tag = tag
    }

    func step(_ message: String) {
        let seconds = (ContinuousClock.now - start).components.seconds
        print("[\(tag) +\(seconds / 60)m\(seconds % 60)s] \(message)")
    }
}
#endif
