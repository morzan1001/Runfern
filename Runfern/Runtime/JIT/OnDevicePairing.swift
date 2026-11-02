#if RUNFERN_JIT
import Foundation
import Observation
import UserNotifications

/// Creating the pairing file on this iPad (iPadOS 27), step by step, for `JITSetup`.
///
/// Runfern advertises itself as a pairable host (`PairingHost`), the person picks it under
/// Settings › Privacy & Security › Developer Mode and types the code Runfern shows, and the
/// resulting file is stored like an imported one. Settings is in front meanwhile, so the work asks
/// iPadOS to continue in the background (`ContinuedWork`) and also sends the code as a notification.
@MainActor
@Observable
final class OnDevicePairing {
    enum Phase: Equatable {
        case idle
        /// Runfern is visible under Developer Mode as `name`.
        case advertising(name: String)
        /// This iPad has connected; `code` is shown once it is known.
        case pairing(name: String, code: String?)
        case done(deviceName: String?)
        case failed(String)
    }

    /// This build can create pairing files (it contains idevice).
    static var isSupported: Bool {
        #if canImport(IDevice)
        true
        #else
        false
        #endif
    }

    private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// Starts a pairing. Must be called as a direct result of a person's action.
    func start() {
        guard task == nil else { return }
        phase = .idle
        task = Task {
            await run()
            task = nil
        }
    }

    /// Runs a pairing to its end, for a caller that continues afterwards. Returns whether a pairing
    /// file was stored. Must be called as a direct result of a person's action.
    func pairToEnd() async -> Bool {
        guard task == nil else { return false }
        phase = .idle
        let running = Task { await run() }
        task = running
        await running.value
        task = nil
        if case .done = phase { return true }
        return false
    }

    func cancel() {
        task?.cancel()
    }

    private static let notificationID = "nrw.cyber.runfern.pairing-code"
    /// Progress units per step of the pairing (advertising, connected, code shown, saved).
    private static let stage = 100

    private func run() async {
        #if canImport(IDevice)
        let notifications = UNUserNotificationCenter.current()
        _ = try? await notifications.requestAuthorization(options: [.alert, .sound])
        defer {
            notifications.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
            notifications.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        }
        do {
            try await ContinuedWork.shared.run(title: String(localized: "Pairing This iPad"),
                                               subtitle: String(localized: "Waiting for Settings")) { handle in
                try await self.pair(progress: handle)
            }
        } catch is CancellationError {
            phase = .failed(PairingHost.HostError.cancelled.localizedDescription)
        } catch {
            phase = .failed(error.localizedDescription)
        }
        #else
        phase = .failed(String(localized: "This build of Runfern cannot create pairing files."))
        #endif
    }

    #if canImport(IDevice)
    private func pair(progress: ContinuedWork.Handle) async throws {
        // A fresh name each time: the pairing file's identifier is derived from it.
        let suffix = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let name = "Runfern-\(suffix)"
        let host = try PairingHost(name: name)
        let advertiser = BonjourAdvertiser(name: host.serviceName, type: PairingHost.serviceType,
                                           port: host.port, txtRecord: host.txtRecord)
        defer { advertiser.stop() }
        try await advertiser.publish()
        try Task.checkCancellation()
        phase = .advertising(name: name)
        progress.report(completed: 1 * Self.stage, of: 4 * Self.stage,
                        subtitle: String(localized: "Open Settings › Privacy & Security › Developer Mode"))

        // iPadOS may end background work that shows no progress, and most of the time is spent
        // waiting for the person; the progress moves a little every few seconds meanwhile.
        let heartbeat = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
                progress.advance(withinStagesOf: Self.stage)
            }
        }
        defer { heartbeat.cancel() }
        // Events come from the pairing thread; they are handled on the main thread, in order.
        let pairing = try await host.pair(timeout: .seconds(5 * 60)) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, name: name, progress: progress) }
            }
        }
        progress.report(completed: 4 * Self.stage, of: 4 * Self.stage, subtitle: String(localized: "Saving"))
        try PairingFile.store(pairing.file)
        phase = .done(deviceName: pairing.deviceName)
    }

    /// Events arrive from the pairing thread, so they may come late or out of order.
    private func handle(_ event: PairingHost.Event, name: String, progress: ContinuedWork.Handle) {
        switch (event, phase) {
        case (.connected, .advertising):
            phase = .pairing(name: name, code: nil)
            progress.report(completed: 2 * Self.stage, of: 4 * Self.stage, subtitle: String(localized: "Connected"))
        case (.code(let code), .advertising), (.code(let code), .pairing):
            show(code, name: name, progress: progress)
        default:
            break
        }
    }

    private func show(_ code: String, name: String, progress: ContinuedWork.Handle) {
        phase = .pairing(name: name, code: code)
        progress.report(completed: 3 * Self.stage, of: 4 * Self.stage, subtitle: String(localized: "Enter \(code) on this iPad"))
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Pairing Code")
        content.body = String(localized: "Enter \(code) in Settings › Privacy & Security › Developer Mode.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    #endif
}

#if canImport(IDevice)
/// Publishes one Bonjour service on the local network until stopped. Uses NetService, which
/// registers the service with the system's mDNSResponder and so needs no multicast entitlement,
/// only Local Network permission and the type in `NSBonjourServices`.
@MainActor
final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    enum AdvertiserError: LocalizedError {
        case localNetworkDenied
        case failed(Int)

        var errorDescription: String? {
            switch self {
            case .localNetworkDenied:
                String(localized: "Runfern may not use the local network. Allow it under Settings › Apps › Runfern › Local Network, then try again.")
            case .failed(let code):
                String(localized: "Runfern could not appear on the local network (error \(code)). Check that Wi-Fi is on.")
            }
        }
    }

    private let service: NetService
    private var continuation: CheckedContinuation<Void, Error>?

    init(name: String, type: String, port: UInt16, txtRecord: [String: String]) {
        service = NetService(domain: "local.", type: type, name: name, port: Int32(port))
        super.init()
        service.delegate = self
        _ = service.setTXTRecord(NetService.data(fromTXTRecord: txtRecord.mapValues { Data($0.utf8) }))
    }

    /// Returns once the service is published. The first time, iPadOS asks for Local Network
    /// permission, and publishing waits for the answer.
    func publish() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                service.publish(options: [.noAutoRename])
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func stop() {
        service.delegate = nil
        service.stop()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        MainActor.assumeIsolated { finish(.success(())) }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        MainActor.assumeIsolated {
            // kDNSServiceErr_PolicyDenied: Local Network permission was denied.
            finish(.failure(code == -65570 ? AdvertiserError.localNetworkDenied : AdvertiserError.failed(code)))
        }
    }
}
#endif
#endif
