#if RUNFERN_JIT
import Foundation
import Observation
import UserNotifications

/// Creating the pairing file on this iPad (iPadOS 27), step by step, for `JITSetup`.
///
/// Runfern advertises itself as a pairable host (`PairingHost`), the person picks it under
/// Settings › Privacy & Security › Developer Mode and types the code Runfern shows, and the
/// resulting file is stored like an imported one. Settings is in front meanwhile, so the caller
/// runs this as background work (`ContinuedWork`), and the code also arrives as a notification.
@MainActor
@Observable
final class OnDevicePairing {
    enum Phase {
        case idle
        /// Runfern is visible under Developer Mode as `name`.
        case advertising(name: String)
        /// This iPad has connected; `code` is shown once it is known.
        case pairing(code: String?)
    }

    /// This build can create pairing files (it contains idevice).
    static var isSupported: Bool {
        #if canImport(IDevice)
        true
        #else
        false
        #endif
    }

    static var unsupportedMessage: String {
        String(localized: "This build cannot create the pairing file on the iPad. Create it on a computer and import it, as described in How Runfern Works.")
    }

    private(set) var phase: Phase = .idle
    /// The last attempt failed because Runfern may not use the local network.
    private(set) var needsLocalNetworkPermission = false

    /// Runs a pairing to its end in the calling task, reporting to the caller's background work.
    /// Returns nil once the pairing file is stored, otherwise why it failed. Cancelling the calling
    /// task ends the pairing.
    func pairToEnd(progress: ContinuedWork.Handle) async -> String? {
        needsLocalNetworkPermission = false
        defer { phase = .idle }
        #if canImport(IDevice)
        let notifications = UNUserNotificationCenter.current()
        defer {
            notifications.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
            notifications.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        }
        do {
            try await pair(progress: progress)
            return nil
        } catch is CancellationError {
            return PairingHost.HostError.cancelled.localizedDescription
        } catch BonjourAdvertiser.AdvertiserError.localNetworkDenied {
            needsLocalNetworkPermission = true
            return BonjourAdvertiser.AdvertiserError.localNetworkDenied.localizedDescription
        } catch {
            return error.localizedDescription
        }
        #else
        return Self.unsupportedMessage
        #endif
    }

    private static let notificationID = "nrw.cyber.runfern.pairing-code"
    /// Progress units per step of the pairing (advertising, connected, code shown, saved).
    private static let unitsPerStage = 100

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
        progress.report(completed: 1 * Self.unitsPerStage, of: 4 * Self.unitsPerStage,
                        subtitle: String(localized: "Open Settings › Privacy & Security › Developer Mode"))

        // Most of the time is spent waiting for the person.
        let heartbeat = progress.heartbeat(withinStagesOf: Self.unitsPerStage)
        defer { heartbeat.cancel() }
        // Events come from the pairing thread; they are handled on the main thread, in order.
        let file = try await host.pair(timeout: .seconds(5 * 60)) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, progress: progress) }
            }
        }
        progress.report(completed: 4 * Self.unitsPerStage, of: 4 * Self.unitsPerStage, subtitle: String(localized: "Saving"))
        try PairingFile.store(file)
    }

    /// Events arrive from the pairing thread, so they may come late or out of order.
    private func handle(_ event: PairingHost.Event, progress: ContinuedWork.Handle) {
        switch (event, phase) {
        case (.connected, .advertising):
            phase = .pairing(code: nil)
            progress.report(completed: 2 * Self.unitsPerStage, of: 4 * Self.unitsPerStage, subtitle: String(localized: "Connected"))
        case (.code(let code), .advertising), (.code(let code), .pairing):
            show(code, progress: progress)
        default:
            break
        }
    }

    private func show(_ code: String, progress: ContinuedWork.Handle) {
        phase = .pairing(code: code)
        progress.report(completed: 3 * Self.unitsPerStage, of: 4 * Self.unitsPerStage, subtitle: String(localized: "Enter \(code) on this iPad"))
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
