import Foundation
import Observation

/// Transient runtime state of the active environment (Session in the data model).
struct Session: Identifiable {
    let id = UUID()
    let projectID: UUID
    let environmentID: UUID
    /// Increases with every start; stale responses from earlier sessions are discarded.
    let generation: Int
    var endpoint: IDEEndpoint?
    var isConnected = true
    /// Guest port → local host port for development server previews (IDE09). Dies with the session.
    var previewPorts: [Int: Int] = [:]
}

/// Owns exactly one active environment and serializes start, switch, and stop (ADR04).
@Observable
final class RuntimeCoordinator {
    private(set) var session: Session?
    private(set) var isBusy = false {
        didSet { busySince = isBusy ? (busySince ?? .now) : nil }
    }
    /// Start of the current start, switch, or stop; shown as elapsed time.
    private(set) var busySince: Date?
    private(set) var lastError: String?

    var activeProjectID: UUID? { session?.projectID }
    var endpoint: IDEEndpoint? { session?.endpoint }
    var isSimulated: Bool { adapter.isSimulated }

    private let store: ProjectStore
    private let sync: SyncCenter
    private let adapter: EmulatorAdapter
    private var generation = 0

    init(store: ProjectStore, sync: SyncCenter, adapter: EmulatorAdapter = SimulatedEmulatorAdapter()) {
        self.store = store
        self.sync = sync
        self.adapter = adapter
    }

    static func configuration(for environment: DevEnvironment, binding: WorkspaceBinding) -> MachineConfiguration {
        MachineConfiguration(environmentID: environment.id, image: AppPaths.image(environment.baseImageId, version: environment.baseCatalogVersion),
                             overlay: AppPaths.overlay(environment.id),
                             workspace: binding.storageMode == .mountedFolder ? .folder(binding) : .workingCopy(AppPaths.workingCopy(binding.id)),
                             memoryMB: environment.effectiveResources.memoryMB,
                             cpuCount: environment.effectiveResources.cpuCount,
                             baseBuildID: environment.baseBuildID)
    }

    /// Opens a project. Another active environment is checkpointed and stopped cleanly first (RUN03).
    func open(_ project: Project) async {
        guard !isBusy else { return }
        if activeProjectID == project.id, endpoint != nil { return }
        guard let target = store.environment(for: project), let binding = store.binding(for: project) else { return }
        guard target.isFullyProvisioned else {
            lastError = String(localized: "Setup has not finished yet.")
            return
        }
        guard binding.accessState != .unavailable else {
            lastError = WorkspaceAccess.AccessError.unavailable.localizedDescription
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        if let active = session, let activeProject = store.project(id: active.projectID) {
            guard await stopActive(activeProject) else { return }
        }

        // Pull in external changes before starting; an unreachable folder does not block local work.
        await sync.sync(binding)

        generation += 1
        let current = generation
        store.setState(.starting, for: target.id)
        session = Session(projectID: project.id, environmentID: target.id, generation: current)
        do {
            let endpoint = try await adapter.start(configuration: Self.configuration(for: target, binding: binding))
            guard session?.generation == current else { return }
            session?.endpoint = endpoint
            store.setState(.running, for: target.id)
            store.markOpened(project)
        } catch {
            // The previous environment stays stored unchanged and can be reopened.
            session = nil
            store.setState(.failed, error: error.localizedDescription, for: target.id)
            lastError = error.localizedDescription
            DiagnosticsLog.record(.error, .runtime, "Start failed: \(error.localizedDescription)")
        }
    }

    /// Ends another project's session before `project` needs the VM, for example for its setup.
    func release(for project: Project) async {
        guard let active = session, active.projectID != project.id, !isBusy,
              let activeProject = store.project(id: active.projectID) else { return }
        isBusy = true
        defer { isBusy = false }
        _ = await stopActive(activeProject)
    }

    /// Stops the active environment on request (RUN05).
    func stopActiveProject() async {
        guard !isBusy, let id = activeProjectID, let project = store.project(id: id) else { return }
        isBusy = true
        defer { isBusy = false }
        _ = await stopActive(project)
    }

    enum PreviewError: LocalizedError {
        case invalidPort
        case notRunning

        var errorDescription: String? {
            switch self {
            case .invalidPort: String(localized: "Choose a port between 1024 and 65535 other than the IDE port 8080.")
            case .notRunning: String(localized: "The environment is not running.")
            }
        }
    }

    /// Makes a development server of the active session reachable for the preview (IDE09).
    /// Ports are forwarded on request only and are never published to the local network.
    func preview(port: Int) async throws -> URL {
        guard (1024...65_535).contains(port), port != 8080 else { throw PreviewError.invalidPort }
        guard let current = session, current.endpoint != nil else { throw PreviewError.notRunning }
        let hostPort = try await adapter.forwardPort(port, environmentID: current.environmentID)
        // A switch in the meantime must never show another environment's server.
        guard session?.generation == current.generation else { throw PreviewError.notRunning }
        session?.previewPorts[port] = hostPort
        return URL(string: "http://127.0.0.1:\(hostPort)")!
    }

    /// Bounded reconnect after the editor connection was lost. Never creates a second VM (RUN05).
    func reconnect() async {
        guard let environmentID = session?.environmentID, session?.endpoint != nil, !isBusy else { return }
        for attempt in 0..<3 {
            if await adapter.isResponsive(environmentID: environmentID) {
                session?.isConnected = true
                lastError = nil
                return
            }
            try? await Task.sleep(for: .seconds(1 << attempt))
        }
        session?.isConnected = false
        lastError = String(localized: "The connection to the environment could not be restored. You can restart it.")
    }

    /// Reported by the web view when the page loses its connection.
    func connectionLost() {
        session?.isConnected = false
        Task { await reconnect() }
    }

    /// The editor view of an ended session must never be shown again.
    private func endSession() {
        session = nil
        IDEWebViewCache.shared.discardUnlessCurrent(nil)
    }

    private func stopActive(_ project: Project) async -> Bool {
        guard let env = store.environment(for: project) else { endSession(); return true }
        // Sync the local checkpoint before stopping; an unfinished sync stays visible in the journal.
        if let binding = store.binding(for: project) { await sync.sync(binding) }
        store.setState(.stopping, for: env.id)
        do {
            try await adapter.stop(environmentID: env.id)
            store.setState(.stopped, for: env.id)
            endSession()
            return true
        } catch {
            store.setState(.failed, error: error.localizedDescription, for: env.id)
            lastError = error.localizedDescription
            DiagnosticsLog.record(.error, .runtime, "Stop failed: \(error.localizedDescription)")
            return false
        }
    }
}
