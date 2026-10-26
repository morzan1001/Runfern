import Network
import Observation

/// Network status for connection-dependent actions (OFF03). Local work never depends on it.
@Observable
final class Connectivity {
    private(set) var isOnline = true
    private(set) var isExpensive = false

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOnline = path.status == .satisfied
                self?.isExpensive = path.isExpensive
            }
        }
        monitor.start(queue: DispatchQueue(label: "Runfern.Connectivity"))
    }

    deinit { monitor.cancel() }
}
