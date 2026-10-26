import Darwin
import Foundation

/// How QEMU runs guest code: interpreted (every build) or translated just in time (sideload builds).
///
/// iPadOS lets an app execute generated code only while a debugger is attached; on devices with
/// the Trusted Execution Monitor the debugger must also prepare the code region. QEMU asks for
/// that with `brk #0x69` when it allocates the region (UTM's protocol, which StikDebug implements).
/// Without a debugger, generated code would crash the app, so the interpreter is used instead.
nonisolated enum QEMUBackend: String, Sendable {
    case interpreter
    case jit

    var frameworkName: String {
        switch self {
        case .interpreter: "qemu-aarch64-softmmu"
        case .jit: "qemu-aarch64-softmmu-jit"
        }
    }

    var library: URL? {
        let url = Bundle.main.privateFrameworksURL?.appending(path: "\(frameworkName).framework/\(frameworkName)")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) ? $0 : nil }
    }

    /// Extra `-accel` options. JIT code is written through one mapping and run from another, and
    /// its smaller cache keeps the debugger's preparation of the code region short.
    var accelOptions: String {
        switch self {
        case .interpreter: "tb-size=512"
        case .jit: "tb-size=\(JITSupport.cacheMB),split-wx=on"
        }
    }

    /// The backend for the next QEMU launch in this process.
    static var preferred: QEMUBackend {
        JITSupport.canUse ? .jit : .interpreter
    }
}

/// Availability of JIT in this build and process.
nonisolated enum JITSupport {
    static let enabledKey = "jitEnabled"

    /// JIT is possible in this installation: the JIT backend is embedded (builds for sideloading) and
    /// the app is signed so that a debugger may attach. App Store installations offer neither.
    static var isIncluded: Bool { QEMUBackend.jit.library != nil && allowsDebugger }

    /// Development signing carries `get-task-allow`; App Store and other distribution signing don't.
    static var allowsDebugger: Bool { provisionedEntitlements["get-task-allow"] as? Bool == true }

    /// Entitlements granted by the embedded provisioning profile; empty for App Store installations.
    nonisolated(unsafe) static let provisionedEntitlements: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // The profile is a signed container; the property list sits in it as plain text.
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any]
        else { return [:] }
        return entitlements
    }()

    /// JIT is on in Settings (the default).
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// A debugger such as StikDebug is attached to the app right now.
    static var isDebuggerAttached: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
        #else
        return false
        #endif
    }

    static var canUse: Bool { isIncluded && isEnabled && isDebuggerAttached }

    /// The backend for QEMU's start in this session. JIT builds first attach the debugger with
    /// the chosen method (`JITAcquisition`); App Store builds always interpret.
    static func backendForLaunch() async -> QEMUBackend {
        #if RUNFERN_JIT
        if isIncluded, isEnabled, !isDebuggerAttached {
            await JITAcquisition.attachDebugger()
        }
        #endif
        return QEMUBackend.preferred
    }

    /// Size of the JIT code cache. In debug builds, launch arguments like `-jitCacheMB 32` shorten
    /// the debugger's preparation of the region for tests.
    static var cacheMB: Int {
        #if DEBUG
        let value = UserDefaults.standard.integer(forKey: "jitCacheMB")
        if value > 0 { return value }
        #endif
        return 256
    }
}
