#if RUNFERN_JIT
import Foundation
import NetworkExtension

/// Runfern's own loopback VPN (PlugIns/RunfernTunnel.appex), through which the JIT helper reaches
/// this iPad's developer services. It is connected only while JIT is being enabled, never on
/// demand, and disconnects when the device sleeps.
@MainActor
enum LoopbackTunnel {
    enum TunnelError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            String(localized: "The Runfern VPN did not connect.")
        }
    }

    static var isAvailable: Bool { JITSupport.allowsTunnel && providerIdentifier != nil }

    private static var providerIdentifier: String? {
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appending(path: "RunfernTunnel.appex"))?.bundleIdentifier }
    }

    /// Connects the tunnel, adding its configuration first if needed; adding it is what asks the
    /// person for permission once.
    static func connect() async throws {
        guard let manager = await manager() else { throw TunnelError.notConnected }
        if manager.connection.status != .connected {
            try manager.connection.startVPNTunnel()
        }
        for _ in 0..<50 {
            if manager.connection.status == .connected { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        manager.connection.stopVPNTunnel()
        throw TunnelError.notConnected
    }

    static func disconnect() async {
        await existingManager()?.connection.stopVPNTunnel()
    }

    private static func existingManager() async -> NETunnelProviderManager? {
        guard let providerIdentifier else { return nil }
        return (try? await NETunnelProviderManager.loadAllFromPreferences())?
            .first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerIdentifier }
    }

    /// The saved configuration, created or corrected so it matches exactly what Runfern needs.
    private static func manager() async -> NETunnelProviderManager? {
        guard let providerIdentifier else { return nil }
        let manager = await existingManager() ?? NETunnelProviderManager()
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerIdentifier
        configuration.serverAddress = JITProtocol.Tunnel.deviceAddress
        configuration.disconnectOnSleep = true
        configuration.includeAllNetworks = false
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "Runfern"
        manager.isOnDemandEnabled = false
        manager.onDemandRules = nil
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            // A configuration has to be loaded again after saving before it can connect.
            try await manager.loadFromPreferences()
            return manager
        } catch {
            DiagnosticsLog.record(.warning, .runtime, "VPN configuration not saved: \(error.localizedDescription)")
            return nil
        }
    }
}
#endif
