#if RUNFERN_JIT
import Foundation
import Observation
import UserNotifications

/// Sets up the built-in JIT in one go, for `JITSetupView`, so the person only acts where iPadOS
/// insists on it: answering its permission prompts, and confirming the pairing in Settings with a
/// code.
///
/// 1. VPN: adds Runfern's VPN configuration, which asks for permission once.
/// 2. Pairing: creates the pairing file on this iPad (`OnDevicePairing`), unless one is stored.
/// 3. Check: connects the VPN and lets the helper reach the developer services with the pairing
///    file, and download and mount the Developer Disk Image (`BuiltInJIT.check`), so the next Linux
///    start uses JIT right away.
///
/// Steps 2 and 3 run as one piece of background work (`ContinuedWork`): the person is in Settings
/// while Runfern waits for the pairing, and may stay there while it checks.
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
    /// The iPad did not accept the stored pairing file; pairing again creates a new one.
    private(set) var canPairAgain = false
    let pairing = OnDevicePairing()
    private var task: Task<Void, Never>?
    /// The step that was running when iPadOS ended the background work.
    private var interruptedStep: Step?

    private enum Step {
        case pairing
        case check
    }

    var isRunning: Bool { task != nil }

    var isDone: Bool { check == .done }

    /// Units of background progress for the check, which shows no progress of its own.
    private static let checkUnits = 100

    /// Runs the steps that are not done yet; `forcingPairing` creates a new pairing file even if
    /// one is stored. Must be called as a direct result of a person's action, because the steps
    /// ask iPadOS to continue in the background.
    func start(forcingPairing: Bool = false) {
        guard task == nil else { return }
        if vpn != .done { vpn = .pending }
        if pairingStep != .done || forcingPairing { pairingStep = .pending }
        check = .pending
        canPairAgain = false
        task = Task {
            await run(forcingPairing: forcingPairing)
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(forcingPairing: Bool) async {
        let needsPairing = forcingPairing || PairingFile.state != .ready
        if needsPairing && !OnDevicePairing.isSupported {
            pairingStep = .failed(String(localized: "This build cannot create the pairing file on the iPad. Create it on a computer and import it, as described in How Runfern Works."))
            return
        }
        // The pairing sends its code as a notification; asking now keeps all of iPadOS's questions
        // together, while the person is still in Runfern.
        if needsPairing {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }

        if vpn != .done {
            vpn = .running
            guard await LoopbackTunnel.requestPermission() else {
                vpn = .failed(String(localized: "iPadOS did not allow Runfern's VPN. Try again and tap Allow."))
                return
            }
            vpn = .done
        }
        guard !Task.isCancelled else { return }

        interruptedStep = nil
        let title = String(localized: "Setting Up JIT")
        let subtitle = needsPairing ? String(localized: "Waiting for Settings") : String(localized: "Checking the connection")
        _ = try? await ContinuedWork.shared.run(title: title, subtitle: subtitle) { progress in
            await self.pairAndCheck(needsPairing: needsPairing, progress: progress)
        }
        // Ended, but not by the person: iPadOS stopped the background work.
        if let interruptedStep, !Task.isCancelled {
            let message = String(localized: "iPadOS stopped the setup while Runfern was in the background. Keep Runfern next to Settings, as a window or in Stage Manager, and try again.")
            switch interruptedStep {
            case .pairing: pairingStep = .failed(message)
            case .check: check = .failed(message)
            }
        }
    }

    /// Steps 2 and 3, inside the background work.
    private func pairAndCheck(needsPairing: Bool, progress: ContinuedWork.Handle) async {
        if needsPairing {
            pairingStep = .running
            guard await pairing.pairToEnd(progress: progress) else {
                if Task.isCancelled {
                    pairingStep = .pending
                    interruptedStep = .pairing
                } else if case .failed(let message) = pairing.phase {
                    pairingStep = .failed(message)
                } else {
                    pairingStep = .failed(String(localized: "The pairing was cancelled."))
                }
                return
            }
            // A new pairing file makes an earlier failure meaningless.
            BuiltInJIT.clearLastError()
        }
        pairingStep = .done
        guard !Task.isCancelled else { return }

        check = .running
        progress.report(completed: 0, of: Self.checkUnits, subtitle: String(localized: "Checking the connection"))
        let heartbeat = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
                progress.advance(withinStagesOf: Self.checkUnits)
            }
        }
        defer { heartbeat.cancel() }
        switch await BuiltInJIT.check() {
        case .ready:
            check = .done
            progress.report(completed: Self.checkUnits, of: Self.checkUnits, subtitle: String(localized: "JIT is ready"))
        case .failed(let message, let needsNewPairing):
            check = .failed(message)
            canPairAgain = needsNewPairing && OnDevicePairing.isSupported
        case .cancelled:
            check = .pending
            interruptedStep = .check
        }
    }
}
#endif
