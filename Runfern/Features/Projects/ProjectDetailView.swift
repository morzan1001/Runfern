import SwiftUI
import UniformTypeIdentifiers

/// Project details (PRJ03/PRJ04) with setup, start, sync, conflicts, and export.
struct ProjectDetailView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(RuntimeCoordinator.self) private var runtime
    @Environment(Provisioner.self) private var provisioner
    @Environment(SyncCenter.self) private var sync
    @Environment(ImageLibrary.self) private var images

    let project: Project
    /// Asks the presenting view to remove the project; `nil` where removal is not offered.
    var requestRemoval: (() -> Void)? = nil
    let openIDE: () -> Void

    @State private var editing = false
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var reassigningFolder = false
    @State private var confirmingReset = false
    @State private var confirmingCardReset = false
    @State private var showingExport = false
    @State private var folderError: String?
    @State private var usage: (environment: Int64, workspace: Int64)?

    var body: some View {
        let env = store.environment(for: project)
        let binding = store.binding(for: project)

        Form {
            // Status and the one action that matters right now, as free-standing cards above the settings.
            Section {
                overview(env)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if let env { environmentSection(env) }
            if let binding { storageSection(binding) }
            if let binding, !sync.status(for: binding).conflicts.isEmpty { conflictSection(binding) }
            if let env { informationSection(env) }
            if let env { maintenanceSection(env) }
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Edit", systemImage: "pencil") { editing = true }
                Menu("More", systemImage: "ellipsis") {
                    Button("Export…", systemImage: "square.and.arrow.up") { showingExport = true }
                    Button("Save as Preset…", systemImage: "square.stack.3d.up") {
                        presetName = project.name
                        savingPreset = true
                    }
                    Divider()
                    Button(project.isArchived ? String(localized: "Restore") : String(localized: "action.archive", defaultValue: "Archive"),
                           systemImage: "archivebox") {
                        store.setArchived(!project.isArchived, for: project)
                    }
                    if let requestRemoval {
                        Button("Remove…", systemImage: "trash", role: .destructive, action: requestRemoval)
                    }
                }
            }
        }
        .task(id: env?.state) { await measureUsage() }
        .fileImporter(isPresented: $reassigningFolder, allowedContentTypes: [.folder]) { result in
            do {
                let fresh = try WorkspaceAccess.makeBinding(for: result.get())
                try store.reassignFolder(of: project, to: fresh)
                folderError = nil
                if let binding = store.binding(for: project) { Task { await sync.sync(binding) } }
            } catch {
                folderError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingExport) { ExportView(project: project) }
        .sheet(isPresented: $editing) { EditProjectView(project: project) }
        .alert("Save as Preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let preset = store.preset(from: project, named: presetName) { store.savePreset(preset) }
            }
            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("New projects can start with the same tools, extensions, and VS Code settings.")
        }
    }

    // MARK: Overview

    private func overview(_ env: DevEnvironment?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if let env {
                    Text(summary(of: env))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !project.details.isEmpty {
                    Text(project.details)
                }
            }
            // Aligned with the section headers below.
            .padding(.horizontal, 20)
            if let env {
                statusCard(env)
            }
        }
        .padding(.vertical, 8)
    }

    /// Exactly one card for the current state; errors and actions always sit inside it.
    @ViewBuilder
    private func statusCard(_ env: DevEnvironment) -> some View {
        let isActive = runtime.activeProjectID == project.id
        let isSettingUp = provisioner.isRunning(project)
        if isSettingUp || !env.isFullyProvisioned {
            let steps = SetupSteps(environment: env, currentStep: provisioner.currentStep[project.id],
                                   progress: provisioner.progress[project.id], isRunning: isSettingUp,
                                   error: isSettingUp ? nil : env.lastError)
            if isSettingUp {
                StatusCard(title: provisioner.waiting.contains(project.id) ? String(localized: "Waiting for Another Setup")
                                : provisioner.currentStep[project.id]?.title ?? String(localized: "Preparing…"),
                           since: provisioner.stepStartedAt[project.id]) {
                    ProgressView()
                } content: {
                    steps
                } actions: {
                    Button("Cancel Setup", role: .cancel) { provisioner.cancel(project) }
                        .buttonStyle(.glass)
                }
            } else {
                let failed = steps.failedStep != nil
                StatusCard(title: failed ? String(localized: "Setup Failed")
                                         : env.completedSteps.isEmpty ? String(localized: "Not Set Up") : String(localized: "Setup Paused")) {
                    Image(systemName: failed ? "xmark.circle.fill" : "pause.circle.fill")
                        .foregroundStyle(failed ? .red : .orange)
                } content: {
                    steps
                } actions: {
                    PrimaryActionButton(title: env.completedSteps.isEmpty ? String(localized: "Start Setup")
                                                                           : String(localized: "Resume Setup"),
                                        systemImage: "arrow.clockwise") { provisioner.start(project) }
                }
            }
        } else if runtime.isBusy, isActive || env.state == .starting || env.state == .stopping {
            StatusCard(title: env.state == .stopping ? String(localized: "Stopping Linux") : String(localized: "Starting Linux"),
                       since: runtime.busySince) {
                ProgressView()
            }
        } else if isActive, runtime.endpoint != nil {
            StatusCard(title: String(localized: "Running")) {
                Image(systemName: "play.circle.fill").foregroundStyle(.green)
            } actions: {
                PrimaryActionButton(title: String(localized: "Open in VS Code"),
                                    systemImage: "chevron.left.forwardslash.chevron.right", action: openIDE)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Stop", systemImage: "stop.fill") { Task { await runtime.stopActiveProject() } }
                    .buttonStyle(.glass)
                    .disabled(runtime.isBusy)
            }
        } else if let error = runtime.activeProjectID == nil ? (runtime.lastError ?? env.lastError) : env.lastError,
                  env.state == .failed {
            StatusCard(title: String(localized: "Start Failed")) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            } content: {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } actions: {
                PrimaryActionButton(title: String(localized: "Try Again"), systemImage: "arrow.clockwise", action: start)
                    .disabled(runtime.isBusy || provisioner.isUsingVM(otherThan: project))
                Button("Reset Environment…", systemImage: "arrow.counterclockwise") { confirmingCardReset = true }
                    .buttonStyle(.glass)
                    .modifier(ResetConfirmation(isPresented: $confirmingCardReset, reset: reset))
            }
        } else {
            let interrupted = env.state == .repairNeeded
            StatusCard(title: interrupted ? String(localized: "Interrupted") : String(localized: "Ready")) {
                Image(systemName: interrupted ? "arrow.counterclockwise.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(interrupted ? .orange : .green)
            } actions: {
                PrimaryActionButton(title: runtime.activeProjectID == nil ? String(localized: "Start and Open")
                                                                          : String(localized: "Switch and Open"),
                                    systemImage: "play.fill", action: start)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(runtime.isBusy || provisioner.isUsingVM(otherThan: project))
            }
        }
    }

    private func reset() {
        store.resetEnvironment(of: project)
        provisioner.start(project)
    }

    private func start() {
        Task {
            await runtime.open(project)
            if runtime.activeProjectID == project.id, runtime.endpoint != nil { openIDE() }
        }
    }

    private func summary(of env: DevEnvironment) -> String {
        let base = Catalog.baseImage(id: env.baseImageId)?.displayName ?? env.baseImageId
        let tools = env.toolchainIds.compactMap { Catalog.toolchain(id: $0)?.name }
        return ([base] + tools).formatted(.list(type: .and, width: .narrow))
    }

    // MARK: Settings

    @ViewBuilder
    private func environmentSection(_ env: DevEnvironment) -> some View {
        let image = Catalog.baseImage(id: env.baseImageId)
        let missing = Catalog.missingComponents(of: env)
        Section {
            NavigationLink {
                InstalledSoftwareView(project: project, environment: env)
            } label: {
                LabeledContent("Installed Software") {
                    Text(env.software.summary)
                }
            }
            environmentOptions(env, image: image)
            if !missing.isEmpty {
                Label("No longer available in the catalog: \(missing.formatted(.list(type: .and)))", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Environment")
        } footer: {
            Text("Software and resources can be changed while the environment is stopped.")
        }
    }

    // MARK: Information

    private func informationSection(_ env: DevEnvironment) -> some View {
        let image = Catalog.baseImage(id: env.baseImageId)
        return Section("Information") {
            if let image {
                LabeledContent("Linux Base", value: image.displayName)
            }
            LabeledContent("Created", value: project.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let lastOpened = project.lastOpenedAt {
                LabeledContent("Last Opened", value: lastOpened.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("Storage Used") {
                if let usage {
                    Text((usage.environment + usage.workspace).formattedBytes)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    // MARK: Maintenance

    @ViewBuilder
    private func maintenanceSection(_ env: DevEnvironment) -> some View {
        Section {
            // A failed start already offers resetting in the status card.
            if env.isFullyProvisioned, env.state != .failed {
                Button("Reset Environment…", systemImage: "arrow.counterclockwise", role: .destructive) { confirmingReset = true }
                    .foregroundStyle(.red)
                    .disabled(runtime.activeProjectID == project.id || provisioner.isRunning(project))
                    .modifier(ResetConfirmation(isPresented: $confirmingReset, reset: reset))
            } else if !provisioner.isRunning(project), !env.completedSteps.isEmpty, let requestRemoval {
                // Same careful path as removing the project from the menu.
                Button("Discard Setup", systemImage: "trash", role: .destructive, action: requestRemoval)
                    .foregroundStyle(.red)
            }
        }
    }

    /// Adding tools (IMG07) and choosing a resource profile (RUN07); both need a stopped environment.
    @ViewBuilder
    private func environmentOptions(_ env: DevEnvironment, image: BaseImage?) -> some View {
        let isBusy = runtime.activeProjectID == project.id || provisioner.isRunning(project)
        Picker("Resources", selection: Binding(get: { env.effectiveResources },
                                               set: { store.setResources($0, for: project) })) {
            ForEach(ResourceProfile.allCases, id: \.self) { profile in
                Text("\(profile.title) – \(profile.memoryMB / 1024) GB, \(profile.cpuCount) CPUs")
                    .tag(profile)
                    .selectionDisabled(!profile.isSupported())
            }
        }
        .disabled(isBusy)
    }

    @ViewBuilder
    private func storageSection(_ binding: WorkspaceBinding) -> some View {
        let status = sync.status(for: binding)
        Section {
            IconValueRow(title: "Folder", value: binding.displayLocation,
                         systemImage: binding.storageMode == .appInternal ? "ipad" : "folder")
            if binding.storageMode == .mountedFolder {
                IconValueRow(title: "Access", value: String(localized: "Direct"), systemImage: "externaldrive.connected.to.line.below")
                if binding.accessState == .unavailable {
                    Label("The folder is not reachable. Choose the folder again.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button("Reassign Folder…") { reassigningFolder = true }
                if let folderError { Text(folderError).foregroundStyle(.red) }
            } else if binding.storageMode == .localFolder {
                IconValueRow(title: "Access", value: String(localized: "Synced Copy"), systemImage: "arrow.triangle.2.circlepath")
                if binding.accessState == .unavailable {
                    Label("The folder is not reachable. Your local working copy is kept; choose the folder again.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                syncStatus(status)
                HStack {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        Task {
                            try? await ContinuedWork.shared.run(title: String(localized: "Syncing “\(project.name)”"),
                                                                subtitle: binding.displayLocation) { _ in
                                await sync.sync(binding)
                            }
                        }
                    }
                        .disabled(status.phase == .syncing)
                    Spacer()
                    Button("Reassign Folder…") { reassigningFolder = true }
                }
                .buttonStyle(.borderless)
                if let folderError { Text(folderError).foregroundStyle(.red) }
                if !status.unsupported.isEmpty {
                    DisclosureGroup("Not Synced (\(status.unsupported.count))") {
                        Text("Symbolic links, cloud files that aren't downloaded, and special files are not transferred.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(status.unsupported, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
            }
        } header: {
            if binding.storageMode == .localFolder { Text("Location and Sync") } else { Text("Location") }
        } footer: {
            if binding.storageMode == .localFolder {
                Text("Not synced: \(DirectoryScanner.excludedNames.sorted().formatted(.list(type: .and))). Git data is always synced.")
            }
        }
    }

    @ViewBuilder
    private func syncStatus(_ status: SyncCenter.Status) -> some View {
        switch status.phase {
        case .syncing:
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
        case .unreachable(let message):
            Label(message, systemImage: "externaldrive.badge.xmark").foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
        Label("Saved Locally", systemImage: "internaldrive")
        if status.pendingLocalChanges > 0 {
            Label("\(status.pendingLocalChanges) changes not yet in the folder", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
        } else if let date = status.lastSyncedAt {
            Label("Synced \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.icloud")
        }
        if status.pendingDownloads > 0 {
            Label("\(status.pendingDownloads) files are still downloading from the cloud and are not synced yet.", systemImage: "icloud.and.arrow.down")
                .foregroundStyle(.secondary)
        }
        if status.wasInterrupted {
            Label("A sync was interrupted and will continue with the next run.", systemImage: "arrow.uturn.forward")
                .foregroundStyle(.orange)
        }
    }

    private func conflictSection(_ binding: WorkspaceBinding) -> some View {
        Section {
            ForEach(sync.status(for: binding).conflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text(conflict.path).font(.body.monospaced())
                    Text(conflict.summary).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Runfern Version") { Task { await sync.resolve(conflict, with: .keepLocal, in: binding) } }
                        Button("Files Version") { Task { await sync.resolve(conflict, with: .keepExternal, in: binding) } }
                        if conflict.canKeepBoth {
                            Button("Keep Both") { Task { await sync.resolve(conflict, with: .keepBoth, in: binding) } }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            Label("Conflicts", systemImage: "exclamationmark.2")
        } footer: {
            Text("Both versions are kept until you decide. The Files version is also preserved inside Runfern.")
        }
    }

    private func measureUsage() async {
        let environmentID = project.environmentId
        let bindingID = project.workspaceBindingId
        usage = await Task.detached(priority: .utility) {
            (DiskUsage.allocatedSize(of: AppPaths.environment(environmentID)),
             DiskUsage.allocatedSize(of: AppPaths.workspaceRoot(bindingID)))
        }.value
    }
}

/// Confirmation before resetting an environment, anchored to the button that asks for it.
private struct ResetConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let reset: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Reset Linux Environment?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Reset and Set Up Again", role: .destructive, action: reset)
        } message: {
            Text("Installed packages and system changes will be lost. Project files are kept.")
        }
    }
}
