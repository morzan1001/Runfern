import Foundation

// Wire format between the app and the GuestAgent inside the Linux guest (Plan 4.1).
// Every frame is one JSON object followed by a newline. The host sends requests;
// the guest answers each request exactly once and may emit events at any time.

/// Version of the wire protocol; the guest must answer `hello` with the same version.
nonisolated let agentProtocolVersion = 1

nonisolated enum AgentCommand: Codable, Equatable, Sendable {
    /// First message of every session; binds the session token to this guest.
    case hello(protocolVersion: Int, sessionToken: String)
    /// Unpacks the toolchain's verified archives from the package folder and puts its commands on
    /// the `PATH`. Must be idempotent.
    case installToolchain(id: String, revision: Int, packages: [AgentPackage], commands: [String: String],
                          environment: [String: String])
    /// Installs VS Code extensions from `.vsix` files in the package folder.
    case installExtensions(files: [String])
    /// Removes a toolchain's files and commands.
    case removeToolchain(id: String, roots: [String], commands: [String])
    /// Uninstalls VS Code extensions by identifier.
    case removeExtensions(ids: [String])
    /// Writes VS Code's user settings (a JSON object) for the editor (agent 1.1 and later).
    case applyEditorSettings(settings: String)
    /// Mounts a folder in Files that the app serves over 9P on a loopback `port` to `/workspace`.
    case mountFolder(port: Int, token: String)
    /// Linux, agent, and code-server report readiness.
    case healthCheck
    /// Starts code-server bound to the guest-local port; the host forwards it.
    case startIDE(port: Int)
    /// Makes a development server in the guest reachable for the preview (IDE09). Never published to the network.
    case forwardPort(guestPort: Int)
    /// Flushes file systems and powers the guest off cleanly.
    case shutdown
}

extension AgentCommand {
    /// Installs a catalog profile from its downloaded archives.
    nonisolated static func installToolchain(_ profile: ToolchainProfile) -> AgentCommand {
        .installToolchain(id: profile.id, revision: profile.revision, packages: profile.packages.map(AgentPackage.init),
                          commands: profile.commands, environment: profile.environment)
    }

    /// Removes a catalog profile again.
    nonisolated static func removeToolchain(_ profile: ToolchainProfile) -> AgentCommand {
        .removeToolchain(id: profile.id, roots: profile.packages.map(\.installRoot), commands: Array(profile.commands.keys))
    }

    /// Installs Open VSX extensions that the package library has downloaded.
    nonisolated static func installExtensions(ids: [String]) -> AgentCommand {
        .installExtensions(files: ids.map(PackageLibrary.extensionFileName(for:)))
    }
}

/// An archive in the package folder and where it goes inside the guest.
nonisolated struct AgentPackage: Codable, Equatable, Sendable {
    let file: String
    let format: String
    let installRoot: String
    let stripComponents: Int

    init(_ package: ToolchainPackage) {
        file = PackageLibrary.fileName(for: package)
        format = package.format.rawValue
        installRoot = package.installRoot
        stripComponents = package.stripComponents
    }
}

nonisolated struct AgentRequest: Codable, Equatable, Sendable {
    let id: Int
    let command: AgentCommand
}

nonisolated struct AgentReply: Codable, Equatable, Sendable {
    let id: Int
    let ok: Bool
    var error: String?
    var payload: [String: String] = [:]
}

nonisolated enum AgentEvent: Codable, Equatable, Sendable {
    case ready(agentVersion: String)
    case progress(step: String, fraction: Double)
    case log(line: String)
    case shutdownComplete
}

/// Anything the guest sends to the host: `{"reply":{…}}` or `{"event":{…}}`.
nonisolated enum AgentFrame: Codable, Equatable, Sendable {
    case reply(AgentReply)
    case event(AgentEvent)

    // Written out because synthesized coding would nest the payload under `_0`, which the
    // Linux agent does not produce.
    private enum CodingKeys: String, CodingKey {
        case reply
        case event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let reply = try container.decodeIfPresent(AgentReply.self, forKey: .reply) {
            self = .reply(reply)
        } else {
            self = .event(try container.decode(AgentEvent.self, forKey: .event))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reply(let reply): try container.encode(reply, forKey: .reply)
        case .event(let event): try container.encode(event, forKey: .event)
        }
    }
}

nonisolated enum AgentCoding {
    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}
