#if RUNFERN_JIT
import Foundation
import NetworkExtension

/// Runfern's own loopback VPN (PlugIns/RunfernTunnel.appex), through which the JIT helper reaches
/// this iPad's developer services. It is connected only while JIT is being enabled, never on
/// demand. It stays connected while the iPad sleeps, because a sleeping iPad would otherwise cut
/// the debugger's connection while QEMU waits at its breakpoint; the VPN stops itself after a
/// while (`PacketTunnelProvider`). Connecting it deselects any other VPN, as iPadOS allows only one.
@MainActor
enum LoopbackTunnel {
    enum TunnelError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            String(localized: "The Runfern VPN did not connect.")
        }
    }

    /// The VPN extension is part of this installation.
    static var isInstalled: Bool { providerIdentifier != nil }

    private static var providerIdentifier: String? {
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appending(path: "RunfernTunnel.appex"))?.bundleIdentifier }
    }

    /// One use of the VPN. The VPN stays connected until the last use is released, so a check in
    /// Settings and a Linux start in another window don't cut each other off.
    final class Lease {
        private var isHeld = true

        fileprivate init() {}

        func release() async {
            guard isHeld else { return }
            isHeld = false
            await LoopbackTunnel.endUse()
        }
    }

    /// Uses that have not been released.
    private static var users = 0

    /// Connects the tunnel, adding its configuration first if needed; adding it is what asks the
    /// person for permission once. Also when this fails or is cancelled, the VPN is left as the
    /// other uses need it.
    static func connect() async throws -> Lease {
        users += 1
        do {
            try await start()
        } catch {
            await endUse()
            throw error
        }
        return Lease()
    }

    private static func start() async throws {
        guard let manager = await manager() else { throw TunnelError.notConnected }
        if manager.connection.status != .connected {
            try manager.connection.startVPNTunnel()
        }
        for _ in 0..<50 {
            if manager.connection.status == .connected { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw TunnelError.notConnected
    }

    fileprivate static func endUse() async {
        users -= 1
        if users == 0 {
            await existingManager()?.connection.stopVPNTunnel()
        }
    }

    /// Adds Runfern's VPN configuration without connecting it, so iPadOS asks for permission during
    /// setup rather than at the first Linux start. Returns whether the configuration is in place.
    static func requestPermission() async -> Bool {
        await manager() != nil
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
        configuration.disconnectOnSleep = false
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
