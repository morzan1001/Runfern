#if RUNFERN_JIT
import Foundation
import UIKit

/// Requests JIT for this process from the StikDebug app, following StikDebug's integration guide
/// (github.com/StikDebug/StikJIT, INTEGRATION.md, “StikDebug” method).
///
/// StikDebug attaches to the running process, runs the script named in the request, and returns
/// to Runfern by itself. The script stays attached until QEMU allocates its code region: QEMU then
/// stops at `brk #0x69` with the region in x0/x1, the script prepares it, moves past the breakpoint,
/// and detaches. That is the protocol of StikDebug's bundled `legacy.js`, which matches UTM's QEMU.
nonisolated enum StikDebug {
    static let scheme = "stikdebug"

    /// The one script for Runfern's JIT allocator; fixed in code, never a user choice.
    static let scriptName = "legacy.js"

    /// The request for this process. QEMU stops at its breakpoint whenever a debugger is attached,
    /// so the script is always sent.
    static func requestURL(bundleID: String, pid: Int32) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(pid)),
            URLQueryItem(name: "script-name", value: scriptName),
        ]
        return components.url
    }

    /// Opens StikDebug with the request and waits until its debugger is attached. Opening fails
    /// when StikDebug isn't installed; opening alone says nothing about success, so only the
    /// attached debugger counts.
    @MainActor static func attachDebugger() async -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let url = requestURL(bundleID: bundleID, pid: getpid()) else { return false }
        guard await UIApplication.shared.open(url) else {
            DiagnosticsLog.record(.warning, .runtime, "StikDebug could not be opened")
            return false
        }
        // Runfern is suspended while StikDebug is in front; the wait pauses with it, so the limit
        // of one minute only counts time in which Runfern runs again.
        return await JITAcquisition.waitForDebugger(checks: 240)
    }
}
#endif
