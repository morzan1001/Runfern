import SwiftUI
import UniformTypeIdentifiers

/// Imports an exported project package after showing its content. The overview picks the
/// package first, so the sheet opens with something to check.
struct ImportProjectView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(Provisioner.self) private var provisioner
    @Environment(ImageLibrary.self) private var images
    @Environment(\.dismiss) private var dismiss

    let onImported: (Project) -> Void

    /// A package to check. Each pick is new, so picking the same file again after a failure checks it again.
    private struct Archive {
        let id = UUID()
        let url: URL
    }

    @State private var archive: Archive
    @State private var pickingArchive = false
    @State private var pickingFolder = false
    @State private var preview: ProjectImporter.Preview?
    @State private var storageMode = StorageMode.appInternal
    @State private var folder: WorkspaceBinding?
    /// True from the start, so “No Package Selected” never flashes before the check begins.
    @State private var isWorking = true
    /// The package couldn't be read; shown in place of the content (A7).
    @State private var prepareError: String?
    /// A folder that couldn't be chosen, shown in the Project Folder footer.
    @State private var folderError: String?
    /// A failed “Import”, shown as an alert (A7).
    @State private var commitError: String?
    /// The files are moving into place; the import can't be stopped then (A3).
    @State private var isImporting = false

    init(archive: URL, onImported: @escaping (Project) -> Void) {
        self.onImported = onImported
        _archive = State(initialValue: Archive(url: archive))
    }

    /// What the package needs and this iPad can't get: components the catalog doesn't list, and a
    /// base it lists but hasn't published (and that isn't installed).
    private var unavailableComponents: [String] {
        guard let preview else { return [] }
        var missing = preview.missingComponents
        if let id = preview.recipe?.base.id, let base = Catalog.baseImage(id: id), !images.isOffered(base) {
            missing.append(String(localized: "\(base.displayName) (not published yet)"))
        }
        return missing
    }

    private var canImport: Bool {
        guard let preview, unavailableComponents.isEmpty, !isWorking, !isImporting,
              !preview.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return storageMode == .appInternal || folder != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let preview {
                    Section {
                        TextField("Name", text: Binding(get: { preview.projectName },
                                                       set: { self.preview?.projectName = $0 }))
                        LabeledContent("Files", value: preview.fileCount.formatted())
                        LabeledContent("Size", value: preview.totalBytes.formattedBytes)
                        if let recipe = preview.recipe {
                            LabeledContent("Linux Base", value: "\(recipe.base.distribution) \(recipe.base.release)")
                            // Only toolchains, by name, like the Languages section of the software page.
                            let names = recipe.toolchains.map { Catalog.toolchain(id: $0.id)?.name ?? $0.id }
                            LabeledContent("Languages", value: names.isEmpty ? String(localized: "None")
                                                                             : names.formatted(.list(type: .and, width: .narrow)))
                        }
                    } header: {
                        Text("Project")
                    } footer: {
                        Text("All files were verified against the package’s checksum list. A Linux environment is set up from the recipe after importing.")
                    }
                    let unavailable = unavailableComponents
                    if !unavailable.isEmpty {
                        Section {
                            ForEach(unavailable, id: \.self) { component in
                                StatusLabel(component)
                            }
                        } header: {
                            Text("Not Available")
                        } footer: {
                            Text("The package needs components this catalog does not offer. Update the catalog and try again.")
                        }
                    }
                    Section {
                        // The same order as in New Project; importing keeps “Only in Runfern” as the default.
                        Picker("Location", selection: $storageMode) {
                            Text("Folder in Files").tag(StorageMode.localFolder)
                            Text("Only in Runfern").tag(StorageMode.appInternal)
                        }
                        if storageMode == .localFolder {
                            if let folder { IconValueRow(title: "Folder", value: folder.displayLocation, systemImage: "folder") }
                            Button(folder == nil ? String(localized: "Choose Folder…") : String(localized: "Choose Another Folder…")) {
                                pickingFolder = true
                            }
                        }
                    } header: {
                        Text("Project Folder")
                    } footer: {
                        // The folder error only concerns the picker, which "Only in Runfern" hides.
                        if storageMode == .localFolder, let folderError {
                            Text(folderError)
                        } else if storageMode == .localFolder, folder == nil {
                            Text("Choose an empty folder to import the project into.")
                        } else if storageMode == .appInternal {
                            Text("Back up the files at any time with “Export”.")
                        }
                    }
                }
            }
            .disabled(isImporting)
            // Progress and problems with the package itself show where its content would be (A7, A8).
            .overlay {
                if preview == nil {
                    if isWorking {
                        ProgressView("Checking Package…")
                    } else {
                        ContentUnavailableView {
                            if prepareError != nil {
                                Label("Couldn’t Open Package", systemImage: "exclamationmark.triangle")
                            } else {
                                Label("No Package Selected", systemImage: "shippingbox")
                            }
                        } description: {
                            Text(prepareError ?? String(localized: "Choose a Runfern project package (.zip)."))
                        } actions: {
                            Button("Choose Package…") { pickingArchive = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .navigationTitle("Import Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { CancelButton().disabled(isImporting) }
                ToolbarItem(placement: .confirmationAction) {
                    if isImporting {
                        ProgressView()
                    } else {
                        Button("Import", role: .confirm) { Task { await commit() } }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!canImport)
                    }
                }
            }
            .interactiveDismissDisabled(isImporting)
            // The folder importer sits on the Form and the package importer on the stack, so two
            // importers never share one view.
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do {
                        folder = try WorkspaceAccess.makeBinding(for: url)
                        folderError = nil
                    } catch {
                        folderError = error.localizedDescription
                    }
                case .failure(let error):
                    folderError = error.localizedDescription
                }
            }
            .errorAlert("Couldn’t Import Project", message: $commitError)
            .task(id: archive.id) { await prepare() }
            // Swiping the sheet down is the same as Cancel. After an import this finds nothing left to delete.
            .onDisappear { if let preview { ProjectImporter.discard(preview) } }
        }
        .fileImporter(isPresented: $pickingArchive, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): archive = Archive(url: url)
            case .failure(let error): prepareError = error.localizedDescription
            }
        }
    }

    /// Extracts and verifies the package off the main thread. A result that arrives after the sheet
    /// closed is deleted right away.
    private func prepare() async {
        let url = archive.url
        isWorking = true
        prepareError = nil
        defer { isWorking = false }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ProjectImporter.Preview, Error> in
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            return Result { try ProjectImporter.prepare(archive: url) }
        }.value
        switch result {
        case .success(let prepared):
            if Task.isCancelled {
                ProjectImporter.discard(prepared)
                return
            }
            if let old = preview { ProjectImporter.discard(old) }
            preview = prepared
        case .failure(let error):
            prepareError = error.localizedDescription
        }
    }

    private func commit() async {
        guard let preview, !isImporting else { return }
        let binding = storageMode == .appInternal ? WorkspaceBinding.appInternal() : folder
        guard let binding else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let project = try await ProjectImporter.commit(preview, store: store, binding: binding)
            provisioner.start(project)
            onImported(project)
            dismiss()
        } catch {
            commitError = error.localizedDescription
        }
    }
}
