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

    private(set) var vpnStep: StepState = .pending
    private(set) var pairingStep: StepState = .pending
    private(set) var checkStep: StepState = .pending
    /// The iPad did not accept the stored pairing file; pairing again creates a new one.
    private(set) var canPairAgain = false
    let pairing = OnDevicePairing()
    private var task: Task<Void, Never>?
    /// The step that was running when iPadOS ended the background work.
    private var interruptedStep: Step?
    /// A new pairing was asked for and has not succeeded yet, so trying again pairs again.
    private var pairingIsForced = false

    /// Ends the background work as unsuccessful for iPadOS.
    private struct SetupIncomplete: Error {}

    private enum Step {
        case pairing
        case check
    }

    var isRunning: Bool { task != nil }

    var isDone: Bool { checkStep == .done }

    /// Units of background progress for the check, which shows no progress of its own.
    private static let unitsPerStage = 100

    /// Runs the steps that are not done yet; `forcingPairing` creates a new pairing file even if
    /// one is stored. Must be called as a direct result of a person's action, because the steps
    /// ask iPadOS to continue in the background.
    func start(forcingPairing: Bool = false) {
        guard task == nil else { return }
        let forcing = forcingPairing || (pairingIsForced && pairingStep != .done)
        pairingIsForced = forcing
        if vpnStep != .done { vpnStep = .pending }
        if pairingStep != .done || forcing { pairingStep = .pending }
        checkStep = .pending
        canPairAgain = false
        task = Task {
            await run(forcingPairing: forcing)
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(forcingPairing: Bool) async {
        let needsPairing = forcingPairing || PairingFile.state != .ready
        if needsPairing && !OnDevicePairing.isSupported {
            pairingStep = .failed(OnDevicePairing.unsupportedMessage)
            return
        }
        // The pairing sends its code as a notification; asking now keeps all of iPadOS's questions
        // together, while the person is still in Runfern.
        if needsPairing {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }

        if vpnStep != .done {
            vpnStep = .running
            guard await LoopbackTunnel.requestPermission() else {
                vpnStep = .failed(String(localized: "iPadOS did not allow Runfern's VPN. Try again and tap Allow."))
                return
            }
            vpnStep = .done
        }
        guard !Task.isCancelled else { return }

        interruptedStep = nil
        let title = String(localized: "Setting Up JIT")
        let subtitle = needsPairing ? String(localized: "Waiting for Settings") : String(localized: "Checking the connection")
        _ = try? await ContinuedWork.shared.run(title: title, subtitle: subtitle) { progress in
            // iPadOS shows whether the work succeeded.
            guard await self.pairAndCheck(needsPairing: needsPairing, progress: progress) else { throw SetupIncomplete() }
        }
        // Ended, but not by the person: iPadOS stopped the background work.
        if let interruptedStep, !Task.isCancelled {
            let message = String(localized: "iPadOS stopped the setup while Runfern was in the background. Keep Runfern next to Settings, as a window or in Stage Manager, and try again.")
            switch interruptedStep {
            case .pairing: pairingStep = .failed(message)
            case .check: checkStep = .failed(message)
            }
        }
    }

    /// Steps 2 and 3, inside the background work. Returns whether JIT is ready.
    private func pairAndCheck(needsPairing: Bool, progress: ContinuedWork.Handle) async -> Bool {
        if needsPairing {
            pairingStep = .running
            if let failure = await pairing.pairToEnd(progress: progress) {
                if Task.isCancelled {
                    pairingStep = .pending
                    interruptedStep = .pairing
                } else {
                    pairingStep = .failed(failure)
                }
                return false
            }
            // A new pairing file makes an earlier failure meaningless.
            BuiltInJIT.clearLastError()
        }
        pairingStep = .done
        guard !Task.isCancelled else {
            interruptedStep = .check
            return false
        }

        checkStep = .running
        progress.report(completed: 0, of: Self.unitsPerStage, subtitle: String(localized: "Checking the connection"))
        let heartbeat = progress.heartbeat(withinStagesOf: Self.unitsPerStage)
        defer { heartbeat.cancel() }
        switch await BuiltInJIT.check() {
        case .ready:
            checkStep = .done
            progress.report(completed: Self.unitsPerStage, of: Self.unitsPerStage, subtitle: String(localized: "JIT is ready"))
            return true
        case .failed(let message, let needsNewPairing):
            checkStep = .failed(message)
            canPairAgain = needsNewPairing && OnDevicePairing.isSupported
            return false
        case .cancelled:
            checkStep = .pending
            interruptedStep = .check
            return false
        }
    }
}
#endif
