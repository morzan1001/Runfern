#if RUNFERN_JIT
import Foundation
import UIKit

/// Runfern's own way to JIT: its loopback VPN reaches the iPad's developer services, and its helper
/// extension attaches StikJIT as the debugger (StikJIT INTEGRATION.md, “Built-in StikJIT”). Only
/// the pairing file has to be created, once: on this iPad (`OnDevicePairing`, Settings ›
/// Performance › Set Up JIT…) or on a computer and imported.
///
/// The VPN is connected only for this: during a check (`check()`), or from the request until the
/// helper has detached, or until the attempt failed or timed out. Meanwhile the iPad does not lock
/// by itself, because a lock would cut the debugger's connection while QEMU waits at its breakpoint.
@MainActor
enum BuiltInJIT {
    /// The VPN, the helper, and the debugger-friendly signing are part of this installation.
    static var isAvailable: Bool { unavailableReason == nil }

    /// Why this installation cannot use the built-in method, or nil if it can. Nothing it depends
    /// on changes while Runfern runs, so it is worked out once, not every time Settings draws
    /// itself. Its file and container lookups come from `JITInstallation`, which `RunfernApp` reads
    /// off the main thread after launch.
    static let unavailableReason: String? = findUnavailableReason()

    private static func findUnavailableReason() -> String? {
        if !JITSupport.allowsTunnel {
            return String(localized: "This installation may not use Runfern's VPN. Built-In needs signing with the Network Extension capability, for example from Xcode with a paid developer account; AltStore, SideStore, and iloader cannot add it. Use StikDebug instead.")
        }
        if !LoopbackTunnel.isInstalled || !JITHelperClient.isInstalled {
            return JITHelperClient.ClientError.missingHelper.errorDescription
        }
        if !JITInstallation.hasStikJIT {
            return String(localized: "StikJIT is missing from this installation. Build Runfern again after running Tools/JIT/build-jit-vendor.sh.")
        }
        if ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil {
            return String(localized: "Built-In does not work inside LiveContainer. Use StikDebug instead.")
        }
        if !JITInstallation.hasAppGroupContainer {
            return JITHelperClient.ClientError.missingAppGroup.errorDescription
        }
        return nil
    }

    /// The last failure, shown in Settings until the next attempt or until the pairing file changes.
    private(set) static var lastError: String?

    /// Forgets the last failure, for example because a new pairing file may fix it.
    static func clearLastError() {
        lastError = nil
    }

    /// Attaches the debugger before QEMU's first start. Returns once it is attached, ready for
    /// QEMU's breakpoint; the helper's request ends later, when the script has detached.
    static func attachDebugger() async -> Bool {
        lastError = nil
        if let unavailableReason { return fail(unavailableReason) }
        let pairing: Data
        do {
            guard let loaded = try PairingFile.load() else { return fail(notSetUpMessage) }
            pairing = loaded
        } catch {
            return fail(error.localizedDescription)
        }

        let wakeLock = WakeLock()
        let vpn: LoopbackTunnel.Lease
        do {
            vpn = try await LoopbackTunnel.connect()
        } catch {
            wakeLock.release()
            return fail(error.localizedDescription)
        }

        let outcome = Outcome()
        let signedRequest: SignedRequest
        do {
            signedRequest = try signed([
                JITProtocol.Key.operation: JITProtocol.Operation.enable,
                JITProtocol.Key.pid: NSNumber(value: getpid()),
                JITProtocol.Key.pairing: pairing,
            ])
        } catch {
            await vpn.release()
            wakeLock.release()
            return fail(error.localizedDescription)
        }
        let helper = Task {
            do {
                outcome.response = try await JITHelperClient.send(signedRequest.request)
            } catch {
                outcome.response = .init(success: false, message: error.localizedDescription)
            }
            signedRequest.discardToken()
            if let response = outcome.response {
                let stage = response.stage.map { " (stage \($0))" } ?? ""
                DiagnosticsLog.record(response.success ? .info : .warning, .runtime, "JIT helper\(stage): \(response.message)")
            }
            await vpn.release()
            wakeLock.release()
        }
        // The first attempt after a restart mounts the Developer Disk Image again, and the first
        // ever, or the first after a reset, also downloads it; that can take a few minutes.
        let attached = await JITAcquisition.waitForDebugger(checks: 1200) {
            outcome.response.map { !$0.success } ?? false
        }
        guard attached else {
            // Taken before cancelling, which would replace a missing answer with a cancellation.
            let response = outcome.response
            helper.cancel()
            await vpn.release()
            wakeLock.release()
            return fail(response.map { explanation(of: $0) } ?? String(localized: "The debugger did not attach in time."))
        }
        return true
    }

    /// The result of `check()`.
    enum CheckResult {
        case ready
        /// `needsNewPairing`: the iPad did not accept the pairing file.
        case failed(String, needsNewPairing: Bool)
        /// The check was cancelled before it had a result.
        case cancelled
    }

    /// Checks the whole way to the iPad's developer services without starting Linux: the VPN, the
    /// pairing file, and the Developer Disk Image, which is downloaded and mounted if needed, so the
    /// next Linux start is quick.
    static func check() async -> CheckResult {
        if let unavailableReason { return checked(.failed(unavailableReason, needsNewPairing: false)) }
        let pairing: Data
        do {
            guard let loaded = try PairingFile.load() else {
                return checked(.failed(notSetUpMessage, needsNewPairing: false))
            }
            pairing = loaded
        } catch {
            return checked(.failed(error.localizedDescription, needsNewPairing: true))
        }
        let wakeLock = WakeLock()
        defer { wakeLock.release() }
        let vpn: LoopbackTunnel.Lease
        do {
            vpn = try await LoopbackTunnel.connect()
        } catch is CancellationError {
            return .cancelled
        } catch {
            return checked(.failed(error.localizedDescription, needsNewPairing: false))
        }
        let result: CheckResult
        do {
            let signedRequest = try signed([
                JITProtocol.Key.operation: JITProtocol.Operation.prepare,
                JITProtocol.Key.pairing: pairing,
            ])
            defer { signedRequest.discardToken() }
            let response = try await JITHelperClient.send(signedRequest.request)
            if response.success {
                result = .ready
            } else {
                result = .failed(explanation(of: response), needsNewPairing: response.stage == JITProtocol.Stage.pairing)
            }
        } catch is CancellationError {
            result = .cancelled
        } catch {
            result = .failed(error.localizedDescription, needsNewPairing: false)
        }
        await vpn.release()
        return checked(result)
    }

    /// Records the result of a check that ran to its end, for Settings and the diagnostics.
    private static func checked(_ result: CheckResult) -> CheckResult {
        switch result {
        case .ready:
            lastError = nil
            DiagnosticsLog.record(.info, .runtime, "JIT check: ready")
        case .failed(let message, _):
            lastError = message
            DiagnosticsLog.record(.warning, .runtime, "JIT check: \(message)")
        case .cancelled:
            break
        }
        return result
    }

    /// Removes the cached Developer Disk Image, so the next attempt downloads it again.
    static func resetDiskImage() async -> String? {
        do {
            let signedRequest = try signed([JITProtocol.Key.operation: JITProtocol.Operation.resetDiskImage])
            defer { signedRequest.discardToken() }
            let response = try await JITHelperClient.send(signedRequest.request)
            return response.success ? nil : response.message
        } catch {
            return error.localizedDescription
        }
    }

    /// What a failed answer of the helper means for the person, followed by StikJIT's own message.
    static func explanation(of response: JITHelperClient.Response) -> String {
        let meaning: String? = switch response.stage ?? "" {
        case JITProtocol.Stage.reachability:
            String(localized: "The iPad's developer services could not be reached through Runfern's VPN. Check that Developer Mode is on and Wi-Fi is connected, and that no other VPN took over.")
        case JITProtocol.Stage.pairing:
            String(localized: "This iPad did not accept the pairing file. Create a new one; this is needed after the passcode was changed or removed, or if the file comes from another iPad.")
        case JITProtocol.Stage.diskImageDownload:
            String(localized: "The Developer Disk Image could not be downloaded. Runfern downloads it once, and again after a reset, which needs the internet.")
        case JITProtocol.Stage.diskImageMount:
            String(localized: "The Developer Disk Image could not be mounted. Reset it under Settings › Performance › Built-In JIT and try again.")
        case JITProtocol.Stage.debugger:
            String(localized: "The debugger could not prepare Linux for JIT.")
        default:
            nil
        }
        guard let meaning else { return response.message }
        return response.message.isEmpty ? meaning : "\(meaning) (\(response.message))"
    }

    private static var notSetUpMessage: String {
        String(localized: "Set up JIT, or import a pairing file, under Settings › Performance › Built-In JIT.")
    }

    /// A request with a fresh one-time token, and the token's file in the shared container, where
    /// only Runfern's own helper can read it (see `JITProtocol.appGroup`).
    private struct SignedRequest {
        var request: [String: Any]
        var tokenFile: URL

        /// The helper deletes the token when it reads it; this removes it if the helper never did.
        func discardToken() {
            try? FileManager.default.removeItem(at: tokenFile)
        }
    }

    private static func signed(_ request: [String: Any]) throws -> SignedRequest {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: JITProtocol.appGroup) else {
            throw JITHelperClient.ClientError.missingAppGroup
        }
        let id = UUID()
        let token = SessionToken.generate()
        let tokenFile = container.appending(path: JITProtocol.requestTokenFile(for: id))
        try Data(token.utf8).write(to: tokenFile, options: [.atomic, .completeFileProtection])
        let fields: [String: Any] = [JITProtocol.Key.requestID: id.uuidString, JITProtocol.Key.token: token]
        return SignedRequest(request: request.merging(fields) { $1 }, tokenFile: tokenFile)
    }

    private static func fail(_ message: String) -> Bool {
        lastError = message
        return false
    }

    /// The helper's answer, once its request has ended.
    private final class Outcome {
        var response: JITHelperClient.Response?
    }

    /// Keeps the iPad from locking by itself while held. Holds may overlap; the iPad may lock again
    /// once the last one is released, as it could before the first.
    private final class WakeLock {
        private static var holders = 0
        private static var wasDisabled = false
        private var isHeld = true

        init() {
            if Self.holders == 0 { Self.wasDisabled = UIApplication.shared.isIdleTimerDisabled }
            Self.holders += 1
            UIApplication.shared.isIdleTimerDisabled = true
        }

        func release() {
            guard isHeld else { return }
            isHeld = false
            Self.holders -= 1
            if Self.holders == 0 { UIApplication.shared.isIdleTimerDisabled = Self.wasDisabled }
        }
    }
}

/// File, bundle, and container lookups that never change while Runfern runs. Read once, off the
/// main thread, after launch (`warmUp()`), so Settings draws without touching the disk.
nonisolated enum JITInstallation {
    /// The bundle identifier of the VPN extension (PlugIns/RunfernTunnel.appex) in this installation.
    static let tunnelIdentifier: String? = plugInIdentifier("RunfernTunnel.appex")
    /// The bundle identifier of the JIT helper (PlugIns/RunfernJITHelper.appex) in this installation.
    static let helperIdentifier: String? = plugInIdentifier("RunfernJITHelper.appex")
    /// StikJIT is embedded where the helper loads it from.
    static let hasStikJIT: Bool = Bundle.main.privateFrameworksURL.map {
        FileManager.default.fileExists(atPath: $0.appending(path: "StikJIT.framework/StikJIT").path(percentEncoded: false))
    } ?? false
    /// Runfern and its helper share an app group. Asking is a call to another process, which also
    /// logs “not entitled” when the signing lacks the group.
    static let hasAppGroupContainer: Bool =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: JITProtocol.appGroup) != nil

    /// Does every lookup now, so later reads only take the cached values.
    static func warmUp() {
        _ = JITSupport.isIncluded
        // `JITSupport.allowsTunnel` reads these; `isIncluded` skips them without the JIT backend.
        _ = JITSupport.provisionedEntitlements
        _ = tunnelIdentifier
        _ = helperIdentifier
        _ = hasStikJIT
        _ = hasAppGroupContainer
    }

    private static func plugInIdentifier(_ name: String) -> String? {
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appending(path: name))?.bundleIdentifier }
    }
}
#endif
