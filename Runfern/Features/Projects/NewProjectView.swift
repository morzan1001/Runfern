import SwiftUI
import UniformTypeIdentifiers

/// Guided project creation (NEW01–NEW03): name, location, environment (or a preset), summary.
struct NewProjectView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(Provisioner.self) private var provisioner
    @Environment(ImageLibrary.self) private var images
    @Environment(RuntimeCoordinator.self) private var runtime
    @Environment(\.dismiss) private var dismiss

    let onCreated: (Project) -> Void

    @State private var name = ""
    @State private var details = ""
    @State private var storageMode = StorageMode.localFolder
    @State private var baseImageId = Catalog.baseImages[0].id
    @State private var software = SoftwareSelection(toolchainIds: ["python-3"])
    @State private var resources: ResourceProfile?
    @State private var editorSettings: String?
    @State private var presetID: UUID?
    private var preset: EnvironmentPreset? { store.presets.first { $0.id == presetID } }
    @State private var binding: WorkspaceBinding?
    @State private var pickingFolder = false
    @State private var errorMessage: String?

    private var baseImage: BaseImage { Catalog.baseImage(id: baseImageId) ?? Catalog.baseImages[0] }
    private var toolchains: [ToolchainProfile] { software.toolchains }
    private var imageDownload: Int64 { images.status(of: baseImage) == .available ? 0 : baseImage.downloadSizeBytes }
    private var totalDownload: Int64 { imageDownload + toolchains.reduce(0) { $0 + $1.estimatedSizeBytes } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Missing or contradictory input, flagged before creation (NEW01). An empty name only disables
    /// “Create”; the missing folder is pointed out in its own section.
    private var canCreate: Bool {
        problems.isEmpty && !trimmedName.isEmpty && !(storageMode == .localFolder && binding == nil)
    }

    private var problems: [String] {
        var result: [String] = []
        if images.status(of: baseImage) == .notPublished, !runtime.isSimulated {
            result.append(String(localized: "\(baseImage.displayName) is not available for download yet."))
        }
        if DiskUsage.availableCapacity < totalDownload + DiskUsage.reserve { result.append(String(localized: "Not enough free storage.")) }
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Description (Optional)", text: $details, axis: .vertical)
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
                    if storageMode == .localFolder, binding == nil {
                        Text("Choose a folder to create the project.")
                    } else if storageMode == .appInternal {
                        Text("Back up the files at any time with “Export”.")
                    }
                }

                Section("Environment") {
                    if !store.presets.isEmpty {
                        Picker("Preset", selection: $presetID) {
                            Text("None").tag(UUID?.none)
                            ForEach(store.presets) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                    // A preset fixes the base and software; only a project without one chooses them.
                    if preset != nil {
                        LabeledContent("Distribution", value: baseImage.displayName)
                        LabeledContent("Software", value: software.summary)
                    } else {
                        Picker("Distribution", selection: $baseImageId) {
                            ForEach(Catalog.baseImages) { Text($0.displayName).tag($0.id) }
                        }
                        SoftwareLink(base: baseImage, selection: $software)
                    }
                    LabeledContent("Image", value: images.status(of: baseImage).title)
                }

                Section("Summary") {
                    LabeledContent("Download", value: totalDownload.formattedBytes)
                    LabeledContent("Available Storage", value: DiskUsage.availableCapacity.formattedBytes)
                }

                if !problems.isEmpty || errorMessage != nil {
                    Section {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill") }
                        if let errorMessage { Label(errorMessage, systemImage: "xmark.octagon.fill") }
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create).disabled(!canCreate)
                }
            }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do {
                        binding = try WorkspaceAccess.makeBinding(for: url)
                        if trimmedName.isEmpty { name = url.lastPathComponent }
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .onChange(of: presetID) {
                guard let preset else {
                    editorSettings = nil
                    resources = nil
                    return
                }
                if Catalog.baseImage(id: preset.baseImageId) != nil { baseImageId = preset.baseImageId }
                software = preset.software
                resources = preset.resources.isSupported() ? preset.resources : nil
                editorSettings = preset.editorSettings
            }
            .onChange(of: baseImageId) {
                // Remove unsupported combinations before they can be created (IMG03).
                software.toolchainIds.removeAll { !baseImage.supportedToolchains.contains($0) }
            }
        }
    }

    private func create() {
        let workspace = storageMode == .appInternal ? WorkspaceBinding.appInternal() : binding
        guard let workspace else { return }
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
            errorMessage = error.localizedDescription
        }
    }
}
