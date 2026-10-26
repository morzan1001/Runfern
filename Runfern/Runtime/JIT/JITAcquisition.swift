#if RUNFERN_JIT
import Foundation

/// How Runfern gets the debugger that JIT needs.
nonisolated enum JITMethod: String, CaseIterable, Sendable {
    /// Runfern's own VPN and helper extension attach StikJIT before the first Linux start.
    case builtIn
    /// Runfern asks the StikDebug app before the first Linux start of the session.
    case stikDebug
    /// Another tool attaches a debugger, for example LLDB from a Mac.
    case externalDebugger
}

/// Attaches a debugger before QEMU's first start in a session, with the method chosen in Settings.
/// If that fails, Linux runs interpreted; Runfern never falls back to another method by itself.
@MainActor
enum JITAcquisition {
    static let methodKey = "jitMethod"

    /// The chosen method; built-in where this installation includes it, otherwise StikDebug.
    static var method: JITMethod {
        UserDefaults.standard.string(forKey: methodKey).flatMap(JITMethod.init(rawValue:))
            ?? (BuiltInJIT.isAvailable ? .builtIn : .stikDebug)
    }

    static func attachDebugger() async {
        let method = method
        let attached: Bool
        switch method {
        case .builtIn: attached = await BuiltInJIT.attachDebugger()
        case .stikDebug: attached = await StikDebug.attachDebugger()
        case .externalDebugger: return
        }
        DiagnosticsLog.record(attached ? .info : .warning, .runtime,
                              attached ? "Debugger attached (\(method.rawValue))"
                                       : "No debugger attached (\(method.rawValue)); using the interpreter")
    }

    /// Waits until a debugger is attached, checking every 250 ms of active app time, at most
    /// `checks` times or until `failed` reports that the attempt is over.
    static func waitForDebugger(checks: Int, failed: () -> Bool = { false }) async -> Bool {
        for _ in 0..<checks {
            if JITSupport.isDebuggerAttached { return true }
            if failed() { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return JITSupport.isDebuggerAttached
    }
}

extension JITSupport {
    /// The signing allows Runfern's own VPN (packet tunnel provider).
    static var allowsTunnel: Bool {
        (provisionedEntitlements["com.apple.developer.networking.networkextension"] as? [String])?
            .contains("packet-tunnel-provider") == true
    }
}
#endif
