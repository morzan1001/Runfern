import Darwin
import Foundation
import Synchronization

/// Runs the embedded QEMU (Plan 4.1, ADR01).
///
/// iPadOS allows no child processes, so QEMU is loaded as a framework and runs on its own thread
/// inside the app, the way UTM SE does. Only one instance runs at a time (ADR04).
///
/// QEMU keeps global state that it never resets, dyld cannot unload images with thread-local
/// variables, and iPadOS only loads code from the signed app bundle. QEMU can therefore run once
/// per app process; a further start needs a fresh process (see `LaunchError.restartRequired`).
nonisolated enum QEMULauncher {
    enum LaunchError: LocalizedError {
        case unavailable
        case alreadyRunning
        case loadFailed(String)
        case exited(Int32)
        case restartRequired
        case guestBootFailed

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "The Linux runtime is not included in this build.")
            case .alreadyRunning: String(localized: "Another Linux environment is still running.")
            case .loadFailed(let reason): String(localized: "The Linux runtime could not be loaded: \(reason)")
            case .exited(let status): String(localized: "The virtual machine stopped unexpectedly (code \(status)).")
            case .restartRequired: String(localized: "Quit and reopen Runfern to start another Linux environment.")
            case .guestBootFailed: String(localized: "Linux could not start. Reset the environment to set it up again.")
            }
        }
    }

    static var isAvailable: Bool { QEMUBackend.interpreter.library != nil }

    /// The backend this process launched QEMU with, once it has.
    static var launchedBackend: QEMUBackend? { launched.withLock { $0 } }

    private typealias InitFunction = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                                    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    private typealias VoidFunction = @convention(c) () -> Void

    /// The QEMU thread while it runs; `exit()` calls from that thread end only the thread.
    private static let qemuThread = Mutex<pthread_t?>(nil)

    /// Lets an `exit()` on the QEMU thread end only that thread.
    ///
    /// `exit()` runs handlers in reverse registration order, including those left behind by earlier
    /// QEMU instances, which would act on stale state and can block. The hook is therefore
    /// registered again right before and right after `qemu_init`, so it always runs before any
    /// QEMU handler. Hooks of finished launches stay registered but do nothing on other threads.
    private static func installExitHook() {
        _ = atexit_b {
            let isQEMU = qemuThread.withLock { thread in thread.map { pthread_equal($0, pthread_self()) != 0 } ?? false }
            if isQEMU {
                QEMULauncher.finishThread(status: 1)
            }
        }
    }
    private static let completion = Mutex<CheckedContinuation<Int32, Error>?>(nil)
    private static let launched = Mutex<QEMUBackend?>(nil)

    /// Runs QEMU with `arguments` (without the program name) until the guest powers off or QEMU quits.
    /// Returns QEMU's status; `0` means a regular shutdown.
    static func run(arguments: [String], backend: QEMUBackend = .interpreter) async throws -> Int32 {
        guard let library = backend.library else { throw LaunchError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let refusal: LaunchError? = completion.withLock { current in
                guard current == nil else { return .alreadyRunning }
                let launchedBefore = launched.withLock { launched in
                    defer { launched = launched ?? backend }
                    return launched != nil
                }
                guard !launchedBefore else { return .restartRequired }
                current = continuation
                return nil
            }
            if let refusal {
                continuation.resume(throwing: refusal)
                return
            }
            let thread = Thread { main(library: library, arguments: [backend.frameworkName] + arguments) }
            thread.name = "nrw.cyber.runfern.qemu"
            thread.stackSize = 8 << 20
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    private static func main(library: URL, arguments: [String]) {
        qemuThread.withLock { $0 = pthread_self() }
        guard let handle = dlopen(library.path(percentEncoded: false), RTLD_LOCAL | RTLD_NOW) else {
            finish(.failure(LaunchError.loadFailed(String(cString: dlerror()))))
            return
        }
        guard let initSymbol = dlsym(handle, "qemu_init"),
              let loopSymbol = dlsym(handle, "qemu_main_loop"),
              let cleanupSymbol = dlsym(handle, "qemu_cleanup") else {
            finish(.failure(LaunchError.loadFailed("missing entry points")))
            return
        }
        let qemuInit = unsafeBitCast(initSymbol, to: InitFunction.self)
        let qemuMainLoop = unsafeBitCast(loopSymbol, to: VoidFunction.self)
        let qemuCleanup = unsafeBitCast(cleanupSymbol, to: VoidFunction.self)

        // QEMU keeps pointers into argv for its whole lifetime, so the strings live until it returns.
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        installExitHook()
        let status = argv.withUnsafeMutableBufferPointer { buffer in
            qemuInit(Int32(arguments.count), buffer.baseAddress, environ)
        }
        guard status == 0 else {
            finish(.success(status))
            return
        }
        installExitHook()
        qemuMainLoop()
        qemuCleanup()
        finish(.success(0))
    }

    private static func finish(_ result: Result<Int32, Error>) {
        qemuThread.withLock { $0 = nil }
        completion.withLock { current in
            current?.resume(with: result)
            current = nil
        }
    }

    /// Called when QEMU calls `exit()` on its own thread: report the status and end only this thread.
    private static func finishThread(status: Int32) -> Never {
        finish(.success(status))
        pthread_exit(nil)
    }
}
