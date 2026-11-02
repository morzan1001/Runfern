#if RUNFERN_JIT
import Foundation
import Observation

/// Sets up the built-in JIT in one go, for `JITSetupView`, so the person only acts where iPadOS
/// insists on it: allowing the VPN, and confirming the pairing in Settings with a code.
///
/// 1. VPN: adds Runfern's VPN configuration, which asks for permission once.
/// 2. Pairing: creates the pairing file on this iPad (`OnDevicePairing`), unless one is stored.
/// 3. Check: connects the VPN and lets the helper reach the developer services with the pairing
///    file, and download and mount the Developer Disk Image (`BuiltInJIT.check`), so the next Linux
///    start uses JIT right away.
///
/// Developer Mode needs no step: a build that can use JIT is signed for development, and iPadOS
/// starts such an app only while Developer Mode is on.
@MainActor
@Observable
final class JITSetup {
    enum StepState: Equatable {
        case pending
        case running
        case done
        case failed(String)
    }

    private(set) var vpn: StepState = .pending
    private(set) var pairingStep: StepState = .pending
    private(set) var check: StepState = .pending
    let pairing = OnDevicePairing()
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    var isDone: Bool { check == .done }

    /// Runs the steps that are not done yet. Must be called as a direct result of a person's
    /// action, because the pairing asks iPadOS to continue in the background.
    func start() {
        guard task == nil else { return }
        if vpn != .done { vpn = .pending }
        if pairingStep != .done { pairingStep = .pending }
        check = .pending
        task = Task {
            await run()
            task = nil
        }
    }

    func cancel() {
        pairing.cancel()
        task?.cancel()
    }

    private func run() async {
        if vpn != .done {
            vpn = .running
            guard await LoopbackTunnel.requestPermission() else {
                vpn = .failed(String(localized: "iPadOS did not allow Runfern's VPN. Try again and tap Allow."))
                return
            }
            vpn = .done
        }
        guard !Task.isCancelled else { return }

        if PairingFile.state == .ready {
            pairingStep = .done
        } else if !OnDevicePairing.isSupported {
            pairingStep = .failed(String(localized: "This build cannot create the pairing file on the iPad. Create it on a computer and import it, as described in How Runfern Works."))
            return
        } else {
            pairingStep = .running
            guard await pairing.pairToEnd() else {
                if case .failed(let message) = pairing.phase {
                    pairingStep = .failed(message)
                } else {
                    pairingStep = .failed(String(localized: "The pairing was cancelled."))
                }
                return
            }
            pairingStep = .done
        }
        guard !Task.isCancelled else { return }

        check = .running
        if let problem = await BuiltInJIT.check() {
            check = .failed(problem)
        } else {
            check = .done
        }
    }
}

#endif
