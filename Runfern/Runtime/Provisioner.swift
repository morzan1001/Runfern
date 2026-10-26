import Foundation
import Observation

/// Sets up environments step by step (Plan 2.2, 4.7, NEW06).
/// Each step is recorded persistently once it succeeds; resuming skips completed steps.
/// A project counts as ready only after the health check has passed.
@Observable
final class Provisioner {
    private(set) var currentStep: [UUID: ProvisioningStep] = [:]
    /// Overall progress from 0 to 1 and the start of the current step, for the setup view.
    private(set) var progress: [UUID: Double] = [:]
    private(set) var stepStartedAt: [UUID: Date] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Setups waiting for an earlier one: only one environment can use the VM at a time (ADR04).
    private(set) var waiting: Set<UUID> = []
    /// Finishes once every setup started so far has finished.
    private var queueTail: Task<Void, Error>?

    private let store: ProjectStore
    private let images: ImageLibrary
    private let packages: PackageLibrary
    private let sync: SyncCenter
    private let connectivity: Connectivity
    private let adapter: EmulatorAdapter

    init(store: ProjectStore, images: ImageLibrary, packages: PackageLibrary? = nil, sync: SyncCenter,
         connectivity: Connectivity, adapter: EmulatorAdapter = SimulatedEmulatorAdapter()) {
        self.store = store
        self.images = images
        self.packages = packages ?? PackageLibrary()
        self.sync = sync
        self.connectivity = connectivity
        self.adapter = adapter
    }

    /// Called before setup needs the VM, so another project's session can end cleanly first.
    var releaseVM: ((Project) async -> Void)?

    func isRunning(_ project: Project) -> Bool { tasks[project.id] != nil }

    /// Another project's setup is using the VM right now, so starting `project` would interrupt it.
    func isUsingVM(otherThan project: Project) -> Bool {
        tasks.keys.contains { $0 != project.id && !waiting.contains($0) }
    }

    func start(_ project: Project) {
        guard tasks[project.id] == nil else { return }
        let previous = tasks.isEmpty ? nil : queueTail
        // Marked right away, so the UI never shows a waiting setup as running.
        if previous != nil { waiting.insert(project.id) }
        let task = Task {
            if let previous {
                // Canceling while waiting ends the wait at once; the earlier setup keeps running.
                _ = try? await awaitDetached(previous)
                waiting.remove(project.id)
            }
            if !Task.isCancelled {
                // Setup may take minutes; iPadOS can continue it in the background with visible progress (R08).
                try? await ContinuedWork.shared.run(title: String(localized: "Setting up “\(project.name)”"),
                                                    subtitle: ProvisioningStep.allCases[0].title) { handle in
                    await self.run(project, progress: handle)
                }
            }
            tasks[project.id] = nil
            currentStep[project.id] = nil
            progress[project.id] = nil
            stepStartedAt[project.id] = nil
        }
        tasks[project.id] = task
        // The next setup waits for all earlier ones, even if this one gives up waiting.
        queueTail = Task {
            _ = try? await previous?.value
            await task.value
        }
    }

    /// Cancels; completed steps are kept and setup can be resumed.
    func cancel(_ project: Project) {
        tasks[project.id]?.cancel()
    }

    // MARK: Flow

    private func run(_ project: Project, progress: ContinuedWork.Handle? = nil) async {
        guard let environment = store.environment(for: project), let binding = store.binding(for: project) else { return }
        store.setState(.provisioning, for: environment.id)

        let steps = ProvisioningStep.allCases
        let unitsPerStep = 100
        for (index, step) in steps.enumerated() {
            progress?.report(completed: index * unitsPerStep, of: steps.count * unitsPerStep, subtitle: step.title)
            guard let current = store.environment(for: project), !current.hasCompleted(step) else { continue }
            currentStep[project.id] = step
            stepStartedAt[project.id] = .now
            self.progress[project.id] = Double(index) / Double(steps.count)
            // Long steps report no progress of their own; iPadOS ends continued work that looks stuck.
            let heartbeat = Task { [progress] in
                let started = ContinuousClock.now
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    let elapsed = Double((ContinuousClock.now - started).components.seconds)
                    let fraction = 0.9 * (1 - exp(-elapsed / step.expectedSeconds))
                    let completed = index * unitsPerStep + Int(fraction * Double(unitsPerStep))
                    progress?.report(completed: completed, of: steps.count * unitsPerStep)
                    self.progress[project.id] = Double(completed) / Double(steps.count * unitsPerStep)
                }
            }
            defer { heartbeat.cancel() }
            do {
                try Task.checkCancellation()
                try await perform(step, project: project, environment: current, binding: binding)
                try Task.checkCancellation()
                store.markCompleted(step, for: environment.id)
            } catch is CancellationError {
                store.setState(.repairNeeded, error: String(localized: "Setup was canceled during “\(step.title)”."), for: environment.id)
                return
            } catch {
                store.setState(.failed, error: "\(step.title): \(error.localizedDescription)", for: environment.id)
                DiagnosticsLog.record(.error, .provisioning, "Step \(step.rawValue) failed: \(error.localizedDescription)")
                return
            }
        }
        progress?.report(completed: steps.count * unitsPerStep, of: steps.count * unitsPerStep)
        store.setState(.ready, for: environment.id)
        DiagnosticsLog.record(.info, .provisioning, "Environment set up with base \(environment.baseImageId)")
    }

    private func perform(_ step: ProvisioningStep, project: Project, environment: DevEnvironment,
                         binding: WorkspaceBinding) async throws {
        guard let image = Catalog.baseImage(id: environment.baseImageId) else {
            throw ProvisioningError.missingComponents(Catalog.missingComponents(of: environment))
        }
        let toolchains = environment.toolchainIds.compactMap(Catalog.toolchain(id:))
        let configuration = RuntimeCoordinator.configuration(for: environment, binding: binding)

        switch step {
        case .checkStorage:
            let imageBytes = images.status(of: image) == .available || image.source == nil ? 0 : image.downloadSizeBytes
            try DiskUsage.ensureAvailable(imageBytes + toolchains.reduce(0) { $0 + $1.estimatedSizeBytes })

        case .fetchBase:
            // The simulated runtime needs no downloads.
            if adapter.isSimulated { return }
            try await images.ensureAvailable(image, isOnline: connectivity.isOnline)

        case .createSystemDisk:
            let imageDirectory = AppPaths.image(image.id, version: environment.baseCatalogVersion)
            try await adapter.createSystemDisk(image: imageDirectory, overlay: AppPaths.overlay(environment.id))
            store.setBaseBuild((try? ImageBundle(directory: imageDirectory).manifest())?.buildID, for: environment.id)

        case .prepareWorkspace:
            try await prepareWorkspace(project: project, binding: binding)

        case .installToolchains:
            await releaseVM?(project)
            let extensions = environment.software.extensions
            let installedExtensions = environment.installedExtensionIds ?? []
            let newExtensions = extensions.filter { !installedExtensions.contains($0) }
            // Linux only unpacks what the app has downloaded and verified; also after tools were added later.
            var phaseStart = ContinuousClock.now
            func finishPhase(_ name: String) {
                DiagnosticsLog.record(.info, .provisioning, "\(name) took \((ContinuousClock.now - phaseStart).components.seconds) s")
                phaseStart = .now
            }
            if !adapter.isSimulated {
                try await packages.ensureAvailable(toolchains.flatMap(\.packages), isOnline: connectivity.isOnline)
                try await packages.ensureExtensions(newExtensions, isOnline: connectivity.isOnline)
                finishPhase("Downloads")
            }
            // Deselected software leaves the environment first.
            let removedTools = (environment.installedToolchainIds ?? []).filter { !environment.toolchainIds.contains($0) }
            try await adapter.removeSoftware(toolchains: removedTools.compactMap(Catalog.toolchain(id:)),
                                             extensions: installedExtensions.filter { !extensions.contains($0) },
                                             configuration: configuration)
            finishPhase("Start and removal")
            try await adapter.installToolchains(toolchains, configuration: configuration)
            finishPhase("Tools")
            if !newExtensions.isEmpty {
                try await adapter.installExtensions(newExtensions, configuration: configuration)
                finishPhase("Extensions")
            }
            store.setInstalledSoftware(toolchains: environment.toolchainIds, extensions: extensions, for: environment.id)
            if let settings = environment.editorSettings, !settings.isEmpty {
                try await adapter.applyEditorSettings(settings, configuration: configuration)
            }

        case .verify:
            await releaseVM?(project)
            try await adapter.verify(configuration: configuration)
            if let recipe = Catalog.recipe(for: environment) {
                try JSONEncoder.store.encode(recipe).write(to: AppPaths.recipe(environment.id), options: .atomic)
            }
        }
    }

    /// Imports existing files from the selected folder and adds the template without overwriting anything.
    private func prepareWorkspace(project: Project, binding: WorkspaceBinding) async throws {
        let files = try WorkspaceFiles(binding)
        try FileManager.default.createDirectory(at: files.url, withIntermediateDirectories: true)

        if binding.storageMode == .localFolder {
            guard await sync.sync(binding) else { throw ProvisioningError.workspaceNotReady }
        }

        let template = Catalog.templateFiles(for: project.source ?? .empty)
        guard !template.isEmpty else { return }
        try await Task.detached {
            for (path, content) in template {
                let target = files.url.appending(path: path)
                guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
                try Data(content.utf8).write(to: target, options: .withoutOverwriting)
            }
        }.value

        if binding.storageMode == .localFolder {
            guard await sync.sync(binding) else { throw ProvisioningError.workspaceNotReady }
        }
    }
}

private extension ProvisioningStep {
    /// Rough duration on the target device, used only to animate progress during long steps.
    var expectedSeconds: Double {
        switch self {
        case .installToolchains: 900
        case .verify: 120
        case .fetchBase: 600
        default: 30
        }
    }
}

enum ProvisioningError: LocalizedError {
    case missingComponents([String])
    case workspaceNotReady

    var errorDescription: String? {
        switch self {
        case .missingComponents(let names):
            String(localized: "No longer available: \(names.formatted(.list(type: .and))).")
        case .workspaceNotReady:
            String(localized: "The project folder could not be fully synced. See the storage location for details.")
        }
    }
}
