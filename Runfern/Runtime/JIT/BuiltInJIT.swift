#if RUNFERN_JIT
import Foundation

/// Runfern's own way to JIT: its loopback VPN reaches the iPad's developer services, and its helper
/// extension attaches StikJIT as the debugger (StikJIT INTEGRATION.md, “Built-in StikJIT”). Only
/// the pairing file comes from outside, once.
///
/// The VPN is connected only for this: from the request until the helper has detached, or until
/// the attempt failed or timed out.
@MainActor
enum BuiltInJIT {
    /// The VPN, the helper, and the debugger-friendly signing are part of this installation.
    static var isAvailable: Bool { LoopbackTunnel.isAvailable && JITHelperClient.isInstalled }

    /// The last failure, shown in Settings until the next attempt.
    private(set) static var lastError: String?

    /// Attaches the debugger before QEMU's first start. Returns once it is attached, ready for
    /// QEMU's breakpoint; the helper's request ends later, when the script has detached.
    static func attachDebugger() async -> Bool {
        lastError = nil
        guard isAvailable else { return fail(String(localized: "The JIT helper is missing from this installation.")) }
        guard let pairing = PairingFile.load() else { return fail(String(localized: "Import a pairing file to use JIT.")) }
        do {
            try await LoopbackTunnel.connect()
        } catch {
            return fail(error.localizedDescription)
        }

        let outcome = Outcome()
        let request: [String: Any]
        do {
            request = try signed([
                JITProtocol.Key.operation: JITProtocol.Operation.enable,
                JITProtocol.Key.pid: NSNumber(value: getpid()),
                JITProtocol.Key.pairing: pairing,
            ])
        } catch {
            await LoopbackTunnel.disconnect()
            return fail(error.localizedDescription)
        }
        let helper = Task {
            do {
                outcome.response = try await JITHelperClient.send(request)
            } catch {
                outcome.response = .init(success: false, message: error.localizedDescription)
            }
            if let response = outcome.response {
                DiagnosticsLog.record(response.success ? .info : .warning, .runtime, "JIT helper: \(response.message)")
            }
            await LoopbackTunnel.disconnect()
        }
        // The first attempt after a reboot also downloads and mounts the Developer Disk Image,
        // which can take a few minutes.
        let attached = await JITAcquisition.waitForDebugger(checks: 1200) {
            outcome.response.map { !$0.success } ?? false
        }
        guard attached else {
            helper.cancel()
            await LoopbackTunnel.disconnect()
            return fail(outcome.response?.message ?? String(localized: "The debugger did not attach in time."))
        }
        return true
    }

    /// Removes the cached Developer Disk Image, so the next attempt downloads it again.
    static func resetDiskImage() async -> String? {
        do {
            let response = try await JITHelperClient.send(try signed([JITProtocol.Key.operation: JITProtocol.Operation.resetDiskImage]))
            return response.success ? nil : response.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Adds a fresh one-time token to `request` and leaves it in the shared container, where only
    /// Runfern's own helper can read it (see `JITProtocol.appGroup`).
    private static func signed(_ request: [String: Any]) throws -> [String: Any] {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: JITProtocol.appGroup) else {
            throw JITHelperClient.ClientError.missingHelper
        }
        let token = SessionToken.generate()
        try Data(token.utf8).write(to: container.appending(path: JITProtocol.requestTokenFile),
                                   options: [.atomic, .completeFileProtection])
        return request.merging([JITProtocol.Key.token: token]) { $1 }
    }

    private static func fail(_ message: String) -> Bool {
        lastError = message
        return false
    }

    /// The helper's answer, once its request has ended.
    private final class Outcome {
        var response: JITHelperClient.Response?
    }
}
#endif
