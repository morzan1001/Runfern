import Foundation

/// Connection to the IDE endpoint of a started environment.
nonisolated struct IDEEndpoint: Sendable {
    let url: URL
    let sessionToken: String
}

/// Resources of a VM. Fixed, verified defaults; customization follows with RUN07.
/// Where the project files that Linux sees at `/workspace` come from.
nonisolated enum WorkspaceSource: Sendable {
    /// The project's working copy inside `AppPaths.workspaces`.
    case workingCopy(URL)
    /// A folder in Files.
    case folder(WorkspaceBinding)
}

nonisolated struct MachineConfiguration: Sendable {
    let environmentID: UUID
    /// Directory of the installed base (see `ImageBundle`).
    let image: URL
    let overlay: URL
    let workspace: WorkspaceSource
    var memoryMB = 3072
    var cpuCount = 4
    /// Build of the base the overlay was created on; `nil` if unknown.
    var baseBuildID: String?
}

/// Encapsulates the concrete emulator including its guest agent (Plan 4.1). The UI knows no QEMU details.
///
/// `QEMUEmulatorAdapter` embeds QEMU in interpreter mode (TCG without JIT), creates the overlay with the
/// base image as its backing file, and talks to the GuestAgent over a virtio-serial channel.
protocol EmulatorAdapter: Sendable {
    /// `true` while no real runtime is integrated. No images are required in that case.
    var isSimulated: Bool { get }
    /// Creates the writable overlay on top of the immutable base in `image` (ADR05).
    func createSystemDisk(image: URL, overlay: URL) async throws
    /// Runs the versioned toolchain recipes inside the guest. Must be repeatable.
    func installToolchains(_ toolchains: [ToolchainProfile], configuration: MachineConfiguration) async throws
    /// Removes toolchains and VS Code extensions that are no longer selected.
    func removeSoftware(toolchains: [ToolchainProfile], extensions: [String], configuration: MachineConfiguration) async throws
    /// Installs additional VS Code extensions inside the guest. Must be repeatable.
    func installExtensions(_ ids: [String], configuration: MachineConfiguration) async throws
    /// Applies VS Code user settings inside the guest.
    func applyEditorSettings(_ settings: String, configuration: MachineConfiguration) async throws
    /// Health check: Linux, the agent, and code-server report readiness.
    func verify(configuration: MachineConfiguration) async throws
    /// Starts the environment and returns the endpoint only after the full readiness check.
    func start(configuration: MachineConfiguration) async throws -> IDEEndpoint
    /// Forwards a guest port to a local host port for the preview (IDE09) and returns the host port.
    func forwardPort(_ guestPort: Int, environmentID: UUID) async throws -> Int
    /// Checks whether the running session still responds (RUN05).
    func isResponsive(environmentID: UUID) async -> Bool
    /// Shuts the environment down cleanly and releases resources and ports.
    func stop(environmentID: UUID) async throws
}
