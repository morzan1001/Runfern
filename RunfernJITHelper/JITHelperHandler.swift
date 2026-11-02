import Foundation
import os
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
///
/// What StikJIT reports (stages, the script's output with the code region and the number of
/// prepared pages) goes to the unified log, subsystem `nrw.cyber.runfern.jit-helper`. The pairing
/// file is never logged.
@objc(JITHelperHandler)
final class JITHelperHandler: NSObject, NSExtensionRequestHandling {
    /// StikJIT's calls block; they run one at a time on this queue (StikJIT INTEGRATION.md).
    private static let queue = DispatchQueue(label: "nrw.cyber.runfern.jit-helper")
    private static let log = Logger(subsystem: "nrw.cyber.runfern.jit-helper", category: "stikjit")

    private struct Answer {
        var success: Bool
        var message: String
        var stage: String?
    }

    func beginRequest(with context: NSExtensionContext) {
        let request = (context.inputItems.first as? NSExtensionItem)?.userInfo ?? [:]
        Self.queue.async {
            let answer = Self.handle(request)
            let item = NSExtensionItem()
            var userInfo: [String: Any] = [JITProtocol.Key.success: answer.success, JITProtocol.Key.message: answer.message]
            if let stage = answer.stage { userInfo[JITProtocol.Key.stage] = stage }
            item.userInfo = userInfo
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }

    private static func handle(_ request: [AnyHashable: Any]) -> Answer {
        #if canImport(StikJIT)
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "StikJIT", directoryHint: .isDirectory)
        let paths = DDIPaths.default(in: root)
        guard isFromRunfern(request) else { return Answer(success: false, message: "The request does not come from Runfern.") }
        let stage = StageRecorder()
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            switch request[JITProtocol.Key.operation] as? String {
            case JITProtocol.Operation.resetDiskImage:
                try StikJIT.resetCachedDDI(at: paths)
                return Answer(success: true, message: "Developer Disk Image removed.")
            case JITProtocol.Operation.enable:
                guard let pid = (request[JITProtocol.Key.pid] as? NSNumber)?.int32Value,
                      let pairing = request[JITProtocol.Key.pairing] as? Data, !pairing.isEmpty else {
                    return Answer(success: false, message: "The request is incomplete.")
                }
                // The pairing file exists only for the duration of the request and is never logged.
                // StikJIT reads it again for every connection, so it must stay readable while the
                // iPad is locked.
                let pairingFile = root.appending(path: "pairing-\(UUID().uuidString).plist")
                try pairing.write(to: pairingFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                defer { try? fileManager.removeItem(at: pairingFile) }
                // The port is fixed: StikJIT's Bonjour lookup could pick another device's service.
                let configuration = StikJIT.Configuration(deviceAddress: JITProtocol.Tunnel.deviceAddress,
                                                          rsdPort: JITProtocol.Tunnel.remotePairingPort,
                                                          automaticallyDiscoverRSDPort: false)
                Self.log.info("Enabling JIT for process \(pid, privacy: .public)")
                // QEMU stops at its breakpoint whenever a debugger is attached, so the script always
                // runs, also where StikJIT detects no Trusted Execution Monitor.
                try StikJIT.enableJIT(targetPID: pid, pairingFile: pairingFile, ddiPaths: paths,
                                      configuration: configuration, script: .legacy, forceScript: true,
                                      preparationProgress: { stage.record($0) },
                                      progress: { line in Self.log.info("\(line, privacy: .public)") })
                Self.log.info("Detached")
                return Answer(success: true, message: "Detached.")
            default:
                return Answer(success: false, message: "Unknown request.")
            }
        } catch {
            Self.log.error("Failed at stage \(stage.current, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return Answer(success: false, message: error.localizedDescription, stage: stage.current)
        }
        #else
        return Answer(success: false, message: "StikJIT is not part of this build.")
        #endif
    }

    /// Whether the request carries the token Runfern left in the shared container for it. The
    /// token is used once: it is deleted before anything else happens.
    private static func isFromRunfern(_ request: [AnyHashable: Any]) -> Bool {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: JITProtocol.appGroup),
              let id = (request[JITProtocol.Key.requestID] as? String).flatMap(UUID.init(uuidString:)),
              let given = request[JITProtocol.Key.token] as? String else { return false }
        let file = container.appending(path: JITProtocol.requestTokenFile(for: id))
        guard let stored = try? Data(contentsOf: file) else { return false }
        try? FileManager.default.removeItem(at: file)
        return JITProtocol.tokensMatch(stored: stored, given: given)
    }
}

#if canImport(StikJIT)
/// The last preparation stage StikJIT reported, as a `JITProtocol.Stage` value. StikJIT may report
/// download progress from another thread.
private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stage = JITProtocol.Stage.reachability
    private static let log = Logger(subsystem: "nrw.cyber.runfern.jit-helper", category: "stikjit")

    var current: String {
        lock.withLock { stage }
    }

    func record(_ preparation: StikJIT.PreparationStage) {
        let next: String
        switch preparation {
        case .checkingReachability: next = JITProtocol.Stage.reachability
        case .checkingDDI: next = JITProtocol.Stage.pairing
        case .downloadingDDI: next = JITProtocol.Stage.diskImageDownload
        case .mountingDDI, .verifyingDDI: next = JITProtocol.Stage.diskImageMount
        case .ready: next = JITProtocol.Stage.debugger
        }
        let changed = lock.withLock {
            defer { stage = next }
            return stage != next
        }
        // Download and mount progress arrive often; only changes of stage are logged.
        if changed { Self.log.info("Stage: \(next, privacy: .public)") }
    }
}
#endif
