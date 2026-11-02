import SwiftUI
import UniformTypeIdentifiers

/// Guided project creation (NEW01–NEW03): name, location, environment (or a preset), summary.
struct NewProjectView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(Provisioner.self) private var provisioner
    @Environment(ImageLibrary.self) private var images
    @Environment(CatalogStore.self) private var catalog
    @Environment(Connectivity.self) private var connectivity
    @Environment(\.dismiss) private var dismiss

    let onCreated: (Project) -> Void

    @State private var name = ""
    @State private var details = ""
    @State private var storageMode = StorageMode.localFolder
    @State private var baseImageId: String
    /// The base the sheet started with; a different one counts as input (A2).
    @State private var startingBaseImageId: String
    @State private var software = Self.initialSoftware
    @State private var resources: ResourceProfile?
    @State private var editorSettings: String?
    @State private var presetID: UUID?
    private var preset: EnvironmentPreset? { store.presets.first { $0.id == presetID } }
    @State private var binding: WorkspaceBinding?
    @State private var pickingFolder = false
    /// Measured once, off the main thread: the capacity query is slow and `body` runs on every
    /// keystroke in Name. `nil` while measuring.
    @State private var availableCapacity: Int64?
    /// A folder that couldn't be chosen, shown in the Project Folder footer.
    @State private var folderError: String?
    /// A failed “Create”, shown as an alert (A7).
    @State private var createError: String?

    init(onCreated: @escaping (Project) -> Void) {
        self.onCreated = onCreated
        // A base this iPad can get: published in the catalog or already installed.
        let base = ImageLibrary.preferredBase?.id ?? ""
        _baseImageId = State(initialValue: base)
        _startingBaseImageId = State(initialValue: base)
    }

    /// `nil` only if the catalog lists no bases at all.
    private var baseImage: BaseImage? { catalog.baseImages.first { $0.id == baseImageId } }
    private var toolchains: [ToolchainProfile] { software.toolchains }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    nonisolated private static let initialSoftware = SoftwareSelection(toolchainIds: ["python-3"])

    /// Input the person would lose by dismissing the sheet (A2), including a changed Linux base or
    /// software choice. A blank sheet closes without asking.
    private var hasInput: Bool {
        !trimmedName.isEmpty || !details.isEmpty || binding != nil || presetID != nil
            || baseImageId != startingBaseImageId || software != Self.initialSoftware
    }

    private func totalDownload(_ status: ImageLibrary.Status) -> Int64 {
        (status == .available ? 0 : baseImage?.downloadSizeBytes ?? 0) + toolchains.reduce(0) { $0 + $1.estimatedSizeBytes }
    }

    /// The chosen base can't be set up on this iPad: not published and not installed.
    private var isUnavailable: Bool { baseImage.map { !images.isOffered($0) } ?? true }

    /// Unknown capacity never blocks: Provisioner checks storage again before downloading.
    private func lacksStorage(_ status: ImageLibrary.Status) -> Bool {
        availableCapacity.map { $0 < totalDownload(status) + DiskUsage.reserve } ?? false
    }

    /// Missing or contradictory input disables “Create” (NEW01); each reason sits in the footer of
    /// the section that causes it (A7). An empty name only disables “Create”.
    private func canCreate(_ status: ImageLibrary.Status) -> Bool {
        !isUnavailable && !lacksStorage(status) && !trimmedName.isEmpty && !(storageMode == .localFolder && binding == nil)
    }

    var body: some View {
        // Read once per pass: every lookup checks the file system.
        let imageStatus = baseImage.map { images.status(of: $0) } ?? .notPublished
        let offered = images.offered(catalog.baseImages)
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Description (Optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Picker("Location", selection: $storageMode) {
                        Text("Folder in Files").tag(StorageMode.localFolder)
                        Text("Only in Runfern").tag(StorageMode.appInternal)
                    }
                    if storageMode == .localFolder {
                        if let binding {
                            IconValueRow(title: "Folder", value: binding.displayLocation, systemImage: "folder")
                        }
                        Button(binding == nil ? String(localized: "Choose Folder…") : String(localized: "Choose Another Folder…")) { pickingFolder = true }
                    }
                } header: {
                    Text("Project Folder")
                } footer: {
                    // The folder error only concerns the picker, which "Only in Runfern" hides.
                    if storageMode == .localFolder, let folderError {
                        Text(folderError)
                    } else if storageMode == .localFolder, binding == nil {
                        Text("Choose a folder to create the project.")
                    } else if storageMode == .appInternal {
                        Text("Back up the files at any time with “Export”.")
                    }
                }

                Section {
                    if !store.presets.isEmpty {
                        Picker("Preset", selection: $presetID) {
                            Text("None").tag(UUID?.none)
                            ForEach(store.presets) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                    // A preset fixes the base and software; only a project without one chooses them.
                    // The same rows as BaseImagePicker, so the layout stays put when a preset is chosen.
                    if preset != nil, let baseImage {
                        LabeledContent("Distribution", value: baseImage.distribution)
                        LabeledContent("Version", value: baseImage.release)
                        LabeledContent("Software", value: software.summary)
                        LabeledContent("Linux Base", value: imageStatus.title)
                    } else if offered.isEmpty {
                        noBaseAvailable
                    } else {
                        BaseImagePicker(selection: $baseImageId)
                        SoftwareLink(base: baseImage, selection: $software)
                        LabeledContent("Linux Base", value: imageStatus.title)
                    }
                } header: {
                    Text("Environment")
                } footer: {
                    if offered.isEmpty, preset == nil {
                        Text("Runfern downloads a Linux base the first time a project needs it. None has been published yet; new ones arrive with catalog updates.")
                    } else if isUnavailable, let baseImage {
                        StatusLabel("\(baseImage.displayName) is not available for download yet.")
                    }
                }

                Section {
                    LabeledContent("Download", value: totalDownload(imageStatus).formattedBytes)
                    LabeledContent("Available Storage") {
                        if let availableCapacity {
                            Text(availableCapacity.formattedBytes)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                } header: {
                    Text("Summary")
                } footer: {
                    if lacksStorage(imageStatus), let availableCapacity {
                        StatusLabel(DiskUsage.SpaceError.insufficient(needed: totalDownload(imageStatus) + DiskUsage.reserve,
                                                                      available: availableCapacity).localizedDescription)
                    }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { CancelButton(hasChanges: hasInput) }
                ToolbarItem(placement: .confirmationAction) {
                    // ⌘↩, not ↩: Description is a multi-line field.
                    Button("Create", role: .confirm, action: create)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canCreate(imageStatus))
                }
            }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do {
                        binding = try WorkspaceAccess.makeBinding(for: url)
                        if trimmedName.isEmpty { name = url.lastPathComponent }
                        folderError = nil
                    } catch {
                        folderError = error.localizedDescription
                    }
                case .failure(let error):
                    folderError = error.localizedDescription
                }
            }
            .onChange(of: presetID) {
                guard let preset else {
                    editorSettings = nil
                    resources = nil
                    return
                }
                if catalog.baseImages.contains(where: { $0.id == preset.baseImageId }) { baseImageId = preset.baseImageId }
                software = preset.software
                resources = preset.resources.isSupported() ? preset.resources : nil
                editorSettings = preset.editorSettings
            }
            .onChange(of: baseImageId) {
                // Remove unsupported combinations before they can be created (IMG03).
                let supported = baseImage?.supportedToolchains ?? []
                software.toolchainIds.removeAll { !supported.contains($0) }
            }
            .onChange(of: catalog.catalogVersion) {
                // A newer catalog may publish a base. Until the person picks one, start with it.
                guard preset == nil, baseImageId == startingBaseImageId, isUnavailable,
                      let first = images.offered(catalog.baseImages).first else { return }
                baseImageId = first.id
                startingBaseImageId = first.id
            }
            .interactiveDismissDisabled(hasInput)
            .errorAlert("Couldn’t Create Project", message: $createError)
            .task {
                availableCapacity = await Task.detached(priority: .userInitiated) { DiskUsage.availableCapacity }.value
            }
        }
    }

    /// Shown instead of the pickers while no base can be set up on this iPad.
    @ViewBuilder
    private var noBaseAvailable: some View {
        LabeledContent("Linux Base", value: String(localized: "None Available"))
        if CatalogStore.updateURL != nil {
            Button {
                Task { await catalog.checkForUpdate(isOnline: connectivity.isOnline) }
            } label: {
                HStack {
                    Label("Check for Catalog Update", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if catalog.isChecking { ProgressView() }
                }
            }
            .disabled(catalog.isChecking || !connectivity.isOnline)
            if let error = catalog.lastError {
                StatusLabel(error, tint: .red)
            }
        }
    }

    private func create() {
        let workspace = storageMode == .appInternal ? WorkspaceBinding.appInternal() : binding
        guard let workspace, let baseImage else { return }
        do {
            let project = try store.createProject(
                name: name, details: details, source: .empty, baseImage: baseImage,
                toolchains: toolchains, extensions: software.customExtensions,
                excludedExtensions: software.excludedExtensions, resources: resources,
                editorSettings: editorSettings, touchOptimized: software.touchOptimized, binding: workspace
            )
            // Setup continues independently of this sheet; the detail view shows progress.
            provisioner.start(project)
            onCreated(project)
            dismiss()
        } catch {
            createError = error.localizedDescription
        }
    }
}
