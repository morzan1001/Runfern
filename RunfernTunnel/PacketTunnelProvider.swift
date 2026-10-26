import Foundation
import NetworkExtension

/// A VPN that leads back to this iPad, so Runfern's JIT helper reaches the device's developer
/// services the way a connected computer would (the approach of LocalDevVPN and SideStore).
///
/// It is deliberately narrow:
/// - only the single address `JITProtocol.Tunnel.deviceAddress` is routed into it; all other
///   traffic, including DNS, keeps using the regular network,
/// - only IPv4 TCP and UDP packets between the VPN's two addresses are turned around
///   (`JITProtocol.Tunnel.turnedAround`); everything else that reaches the tunnel is dropped, and
///   nothing ever leaves the device through it,
/// - it stops itself after `maximumLifetime`, also when someone starts it from the Settings app.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    /// Long enough for a first JIT start, which may download the Developer Disk Image.
    private static let maximumLifetime: Duration = .seconds(10 * 60)

    private var lifetime: Task<Void, Never>?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let ipv4 = NEIPv4Settings(addresses: [JITProtocol.Tunnel.interfaceAddress], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: JITProtocol.Tunnel.deviceAddress, subnetMask: "255.255.255.255")]
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: JITProtocol.Tunnel.deviceAddress)
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if error == nil {
                reflectPackets()
                lifetime = Task { [weak self] in
                    try? await Task.sleep(for: Self.maximumLifetime)
                    guard !Task.isCancelled else { return }
                    self?.cancelTunnelWithError(nil)
                }
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifetime?.cancel()
        completionHandler()
    }

    private func reflectPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var reflected: [Data] = []
            var families: [NSNumber] = []
            for (packet, family) in zip(packets, protocols) where family.int32Value == AF_INET {
                if let turned = JITProtocol.Tunnel.turnedAround([UInt8](packet)) {
                    reflected.append(Data(turned))
                    families.append(family)
                }
            }
            if !reflected.isEmpty {
                packetFlow.writePackets(reflected, withProtocols: families)
            }
            reflectPackets()
        }
    }
}
