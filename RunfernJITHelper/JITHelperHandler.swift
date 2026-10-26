import Foundation
#if canImport(StikJIT)
import StikJIT
#endif

/// The debugger half of Runfern's built-in JIT. A process cannot debug itself, so Runfern starts
/// this extension and sends it its process ID and the pairing file. StikJIT connects to the iPad's
/// developer services through Runfern's loopback VPN, attaches, and runs its bundled `legacy.js`,
/// which prepares QEMU's code region at `brk #0x69` and detaches. The request lasts until then.
///
/// The helper only acts for Runfern: every request must carry the one-time token Runfern left in
/// their shared container (`JITProtocol.appGroup`), which no other app can read.
@objc(JITHelperHandler)
final class JITHelperHandler: NSObject, NSExtensionRequestHandling {
    /// StikJIT's calls block; they run one at a time on this queue (StikJIT INTEGRATION.md).
    private static let queue = DispatchQueue(label: "nrw.cyber.runfern.jit-helper")

    func beginRequest(with context: NSExtensionContext) {
        let request = (context.inputItems.first as? NSExtensionItem)?.userInfo ?? [:]
        Self.queue.async {
            let (success, message) = Self.handle(request)
            let item = NSExtensionItem()
            item.userInfo = [JITProtocol.Key.success: success, JITProtocol.Key.message: message]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }

    private static func handle(_ request: [AnyHashable: Any]) -> (Bool, String) {
        #if canImport(StikJIT)
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "StikJIT", directoryHint: .isDirectory)
        let paths = DDIPaths.default(in: root)
        guard isFromRunfern(request) else { return (false, "The request does not come from Runfern.") }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            switch request[JITProtocol.Key.operation] as? String {
            case JITProtocol.Operation.resetDiskImage:
                try StikJIT.resetCachedDDI(at: paths)
                return (true, "Developer Disk Image removed.")
            case JITProtocol.Operation.enable:
                guard let pid = (request[JITProtocol.Key.pid] as? NSNumber)?.int32Value,
                      let pairing = request[JITProtocol.Key.pairing] as? Data, !pairing.isEmpty else {
                    return (false, "The request is incomplete.")
                }
                // The pairing file exists only for the duration of the request and is never logged.
                let pairingFile = root.appending(path: "pairing-\(UUID().uuidString).plist")
                try pairing.write(to: pairingFile, options: [.atomic, .completeFileProtection])
                defer { try? fileManager.removeItem(at: pairingFile) }
                // QEMU stops at its breakpoint whenever a debugger is attached, so the script always
                // runs, also where StikJIT detects no Trusted Execution Monitor.
                try StikJIT.enableJIT(targetPID: pid, pairingFile: pairingFile, ddiPaths: paths,
                                      script: .legacy, forceScript: true)
                return (true, "Detached.")
            default:
                return (false, "Unknown request.")
            }
        } catch {
            return (false, error.localizedDescription)
        }
        #else
        return (false, "StikJIT is not part of this build.")
        #endif
    }

    /// Whether the request carries the token Runfern left in the shared container. The token is
    /// used once: it is deleted before anything else happens.
    private static func isFromRunfern(_ request: [AnyHashable: Any]) -> Bool {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: JITProtocol.appGroup),
              let given = request[JITProtocol.Key.token] as? String else { return false }
        let file = container.appending(path: JITProtocol.requestTokenFile)
        guard let stored = try? Data(contentsOf: file) else { return false }
        try? FileManager.default.removeItem(at: file)
        let expected = [UInt8](stored)
        let candidate = Array(given.utf8)
        guard expected.count >= 32, expected.count == candidate.count else { return false }
        return zip(expected, candidate).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
