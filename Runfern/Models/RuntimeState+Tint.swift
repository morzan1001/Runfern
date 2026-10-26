import SwiftUI

extension RuntimeState {
    /// Color that represents the state in lists and cards.
    var tint: Color {
        switch self {
        case .running: .green
        case .starting, .stopping, .provisioning: .blue
        case .ready, .stopped: .secondary
        case .repairNeeded: .orange
        case .failed: .red
        }
    }
}
