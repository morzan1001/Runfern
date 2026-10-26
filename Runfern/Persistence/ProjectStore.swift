import Foundation
import Observation

/// Persistent inventory of projects, environments, and folder bindings.
/// Every change is written atomically right away (DAT03).
@Observable
final class ProjectStore {
    enum StoreError: LocalizedError {
        case emptyName
        case incompatibleSelection
        case workspaceAlreadyRegistered(String)

        var errorDescription: String? {
            switch self {
            case .emptyName: String(localized: "Please enter a project name.")
            case .incompatibleSelection: String(localized: "This combination of Linux base and toolchain profile is not supported.")
            case .workspaceAlreadyRegistered(let name):
                String(localized: "This folder already belongs to the project “\(name)”. Each folder has exactly one write owner.")
            }
        }
    }

    private(set) var snapshot = StoreSnapshot()
    private(set) var lastSaveError: String?
    /// Environments marked as needing repair at launch after an unclean exit (DAT04).
    private(set) var recoveredEnvironmentIDs: Set<UUID> = []
    private let fileURL: URL

    init(fileURL: URL = AppPaths.store) {
        self.fileURL = fileURL
        load()
    }

    // MARK: Access

    var activeProjects: [Project] { snapshot.projects.filter { !$0.isArchived } }
    var archivedProjects: [Project] { snapshot.projects.filter(\.isArchived) }

    func environment(for project: Project) -> DevEnvironment? {
        snapshot.environments.first { $0.id == project.environmentId }
    }

    func binding(for project: Project) -> WorkspaceBinding? {
        snapshot.bindings.first { $0.id == project.workspaceBindingId }
    }

    func project(id: UUID) -> Project? {
        snapshot.projects.first { $0.id == id }
    }

    /// Base images still referenced by at least one environment (referenceCount in the data model).
    /// Directory names of the base images that environments still build on.
    var referencedImageDirectories: Set<String> {
        Set(snapshot.environments.map { AppPaths.imageDirectoryName($0.baseImageId, version: $0.baseCatalogVersion) })
    }

    // MARK: Creation

    /// Registers project and environment in the provisioning state. Only the Provisioner makes it ready to start.
    func createProject(name: String, details: String, source: ProjectSource, baseImage: BaseImage,
                       toolchains: [ToolchainProfile], extensions: [String] = [], excludedExtensions: [String] = [],
                       resources: ResourceProfile? = nil, editorSettings: String? = nil,
                       touchOptimized: Bool = false, binding: WorkspaceBinding) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyName }
        guard toolchains.allSatisfy({ baseImage.supportedToolchains.contains($0.id) }) else {
            throw StoreError.incompatibleSelection
        }
        if binding.isInFiles, let owner = owner(ofWorkspace: binding.workspaceIdentity) {
            throw StoreError.workspaceAlreadyRegistered(owner.name)
        }

        let environment = DevEnvironment(
            id: UUID(), baseImageId: baseImage.id, baseCatalogVersion: baseImage.catalogVersion,
            toolchainIds: toolchains.map(\.id), state: .provisioning, completedSteps: [], lastError: nil,
            resources: resources,
            extensionIds: extensions.isEmpty ? nil : extensions,
            editorSettings: editorSettings,
            excludedExtensionIds: excludedExtensions.isEmpty ? nil : excludedExtensions,
            touchOptimized: touchOptimized ? true : nil
        )
        let project = Project(
            id: UUID(), name: trimmed, details: details, environmentId: environment.id,
            workspaceBindingId: binding.id, createdAt: .now, lastOpenedAt: nil, isArchived: false, source: source
        )
        snapshot.bindings.append(binding)
        snapshot.environments.append(environment)
        snapshot.projects.append(project)
        save()
        return project
    }

    // MARK: Changes

    func rename(_ project: Project, name: String, details: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = snapshot.projects.firstIndex(where: { $0.id == project.id }) else { return }
        snapshot.projects[i].name = trimmed
        snapshot.projects[i].details = details
        save()
    }

    func markOpened(_ project: Project) {
        guard let i = snapshot.projects.firstIndex(where: { $0.id == project.id }) else { return }
        snapshot.projects[i].lastOpenedAt = .now
        save()
    }

    func setState(_ state: RuntimeState, error: String? = nil, for environmentId: UUID) {
        update(environmentId) { $0.state = state; $0.lastError = error }
        if state == .running || state == .ready { recoveredEnvironmentIDs.remove(environmentId) }
    }

    /// The recovery notice was read; the environments stay marked as needing repair.
    func acknowledgeRecovery() {
        recoveredEnvironmentIDs.removeAll()
    }

    func markCompleted(_ step: ProvisioningStep, for environmentId: UUID) {
        update(environmentId) { env in
            if !env.completedSteps.contains(step.rawValue) { env.completedSteps.append(step.rawValue) }
        }
    }

    func setArchived(_ archived: Bool, for project: Project) {
        guard let i = snapshot.projects.firstIndex(where: { $0.id == project.id }) else { return }
        snapshot.projects[i].isArchived = archived
        save()
    }

    /// Reassigns a project to a folder after access was revoked or the folder moved (FIL03).
    func reassignFolder(of project: Project, to fresh: WorkspaceBinding) throws {
        guard let i = snapshot.bindings.firstIndex(where: { $0.id == project.workspaceBindingId }) else { return }
        if let owner = owner(ofWorkspace: fresh.workspaceIdentity), owner.id != project.id {
            throw StoreError.workspaceAlreadyRegistered(owner.name)
        }
        // The identifier stays the same so the working copy and journal are kept. A synced folder
        // keeps syncing, so local changes still reach the new folder; a mounted one follows the new folder.
        if snapshot.bindings[i].storageMode == .mountedFolder { snapshot.bindings[i].storageMode = fresh.storageMode }
        snapshot.bindings[i].bookmark = fresh.bookmark
        snapshot.bindings[i].displayPath = fresh.displayPath
        snapshot.bindings[i].workspaceIdentity = fresh.workspaceIdentity
        snapshot.bindings[i].accessState = .granted
        save()
    }

    /// Records which build of the base the system disk was created on.
    func setBaseBuild(_ buildID: String?, for environmentId: UUID) {
        update(environmentId) { $0.baseBuildID = buildID }
    }

    // MARK: Presets

    var presets: [EnvironmentPreset] { snapshot.presets ?? [] }

    func savePreset(_ preset: EnvironmentPreset) {
        var all = presets
        if let i = all.firstIndex(where: { $0.id == preset.id }) { all[i] = preset } else { all.append(preset) }
        snapshot.presets = all
        save()
    }

    func removePreset(_ preset: EnvironmentPreset) {
        snapshot.presets = presets.filter { $0.id != preset.id }
        save()
    }

    /// A preset that recreates the setup of an existing project.
    func preset(from project: Project, named name: String) -> EnvironmentPreset? {
        guard let env = environment(for: project) else { return nil }
        return EnvironmentPreset(id: UUID(), name: name, baseImageId: env.baseImageId, toolchainIds: env.toolchainIds,
                                 extensionIds: env.customExtensions, resources: env.effectiveResources,
                                 editorSettings: env.editorSettings, excludedExtensionIds: env.excludedExtensionIds,
                                 touchOptimized: env.touchOptimized)
    }

    /// Replaces tools and extensions. Setup installs what is new, removes what was deselected, and
    /// checks the environment again; everything else stays as it is.
    func setSoftware(_ software: SoftwareSelection, for project: Project) {
        guard let current = environment(for: project)?.software, !current.installsSameSoftware(as: software) else {
            // Only the editor changes; Linux keeps its setup.
            update(project.environmentId) { $0.touchOptimized = software.touchOptimized }
            return
        }
        update(project.environmentId) { env in
            env.touchOptimized = software.touchOptimized
            env.toolchainIds = software.toolchainIds
            env.extensionIds = software.customExtensions
            env.excludedExtensionIds = software.excludedExtensions
            env.completedSteps.removeAll {
                $0 == ProvisioningStep.installToolchains.rawValue || $0 == ProvisioningStep.verify.rawValue
            }
            env.state = .provisioning
            env.lastError = nil
        }
    }

    /// Records what the guest has after a successful install step.
    func setInstalledSoftware(toolchains: [String], extensions: [String], for environmentId: UUID) {
        update(environmentId) { env in
            env.installedToolchainIds = toolchains
            env.installedExtensionIds = extensions
        }
    }

    /// Changes the VM resources; validated presets only (RUN07). Takes effect on the next start.
    func setResources(_ profile: ResourceProfile, for project: Project) {
        guard profile.isSupported() else { return }
        update(project.environmentId) { $0.resources = profile }
    }

    /// Resets only the Linux environment; project files and working copy are kept (Plan 4.7).
    func resetEnvironment(of project: Project) {
        try? FileManager.default.removeItem(at: AppPaths.environment(project.environmentId))
        update(project.environmentId) { env in
            env.completedSteps = []
            env.state = .provisioning
            env.lastError = nil
            env.baseBuildID = nil
        }
    }

    /// Creates an independent copy with new identities (PRJ07, Plan 4.7). The copy's files live in Runfern;
    /// a reference to the same external folder would not be an independent copy. With `includeSystemState`
    /// the environment overlay is copied too, otherwise the copy is set up fresh from the recipe.
    func duplicate(_ project: Project, name: String, includeSystemState: Bool) throws -> Project {
        guard let environment = environment(for: project), let source = binding(for: project) else {
            throw StoreError.emptyName
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyName }

        let fm = FileManager.default
        let binding = WorkspaceBinding.appInternal()
        var copy = DevEnvironment(id: UUID(), baseImageId: environment.baseImageId,
                                  baseCatalogVersion: environment.baseCatalogVersion,
                                  toolchainIds: environment.toolchainIds, state: .provisioning,
                                  completedSteps: [], lastError: nil, resources: environment.resources,
                                  extensionIds: environment.extensionIds, editorSettings: environment.editorSettings,
                                  excludedExtensionIds: environment.excludedExtensionIds)
        try fm.createDirectory(at: AppPaths.workspaceRoot(binding.id), withIntermediateDirectories: true)
        let sourceFiles = try WorkspaceFiles(source)
        if fm.fileExists(atPath: sourceFiles.url.path(percentEncoded: false)) {
            try fm.copyItem(at: sourceFiles.url, to: AppPaths.workingCopy(binding.id))
        } else {
            try fm.createDirectory(at: AppPaths.workingCopy(binding.id), withIntermediateDirectories: true)
        }
        if includeSystemState {
            if fm.fileExists(atPath: AppPaths.environment(environment.id).path(percentEncoded: false)) {
                try fm.createDirectory(at: AppPaths.environments, withIntermediateDirectories: true)
                try fm.copyItem(at: AppPaths.environment(environment.id), to: AppPaths.environment(copy.id))
            }
            copy.completedSteps = environment.completedSteps
            copy.state = environment.isFullyProvisioned ? .ready : .provisioning
        }

        let duplicate = Project(id: UUID(), name: trimmed, details: project.details, environmentId: copy.id,
                                workspaceBindingId: binding.id, createdAt: .now, lastOpenedAt: nil,
                                isArchived: false, source: .empty)
        snapshot.bindings.append(binding)
        snapshot.environments.append(copy)
        snapshot.projects.append(duplicate)
        save()
        return duplicate
    }

    /// Removes the entry, environment, and app-managed working copy. The selected folder in Files
    /// is never touched; shared base images remain until cleanup (PRJ06).
    func remove(_ project: Project) {
        snapshot.projects.removeAll { $0.id == project.id }
        snapshot.environments.removeAll { $0.id == project.environmentId }
        snapshot.bindings.removeAll { $0.id == project.workspaceBindingId }
        save()
        try? FileManager.default.removeItem(at: AppPaths.environment(project.environmentId))
        try? FileManager.default.removeItem(at: AppPaths.workspaceRoot(project.workspaceBindingId))
    }

    /// Checks folder access; bookmarks are refreshed when needed (FIL02/FIL03).
    func refreshAccess() {
        for i in snapshot.bindings.indices where snapshot.bindings[i].isInFiles {
            let result = WorkspaceAccess.check(snapshot.bindings[i])
            snapshot.bindings[i].accessState = result.state
            if let data = result.refreshedBookmark { snapshot.bindings[i].bookmark = data }
        }
        save()
    }

    // MARK: Private

    private func owner(ofWorkspace identity: String) -> Project? {
        let clashing = snapshot.bindings.filter {
            $0.isInFiles && WorkspaceAccess.overlaps($0.workspaceIdentity, identity)
        }
        return snapshot.projects.first { project in clashing.contains { $0.id == project.workspaceBindingId } }
    }

    private func update(_ environmentId: UUID, _ change: (inout DevEnvironment) -> Void) {
        guard let i = snapshot.environments.firstIndex(where: { $0.id == environmentId }) else { return }
        change(&snapshot.environments[i])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder.store.decode(StoreSnapshot.self, from: data) else {
            // Never discard silently: keep the unreadable inventory for analysis.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            lastSaveError = String(localized: "The saved project inventory could not be read and was backed up as \(backup.lastPathComponent).")
            return
        }
        snapshot = decoded
        // After an unclean exit no process is alive anymore: running states count as needing repair (DAT04).
        for i in snapshot.environments.indices {
            switch snapshot.environments[i].state {
            case .starting, .running, .stopping, .provisioning:
                snapshot.environments[i].state = .repairNeeded
                recoveredEnvironmentIDs.insert(snapshot.environments[i].id)
            default: break
            }
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder.store.encode(snapshot)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastSaveError = nil
        } catch {
            // Not silent: the UI shows the error.
            lastSaveError = error.localizedDescription
            DiagnosticsLog.record(.error, .storage, "Saving the project inventory failed: \(error.localizedDescription)")
        }
    }
}

/// The JSON format of Runfern's own files: readable, stable key order, ISO 8601 dates.
nonisolated extension JSONEncoder {
    static var store: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

nonisolated extension JSONDecoder {
    static var store: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
