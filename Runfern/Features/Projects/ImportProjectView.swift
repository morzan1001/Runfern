import SwiftUI
import UniformTypeIdentifiers

/// Imports an exported project package after showing its content (NEW05).
struct ImportProjectView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(Provisioner.self) private var provisioner
    @Environment(\.dismiss) private var dismiss

    let onImported: (Project) -> Void

    @State private var pickingArchive = true
    @State private var pickingFolder = false
    @State private var preview: ProjectImporter.Preview?
    @State private var storageMode = StorageMode.appInternal
    @State private var folder: WorkspaceBinding?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var canImport: Bool {
        guard let preview, preview.missingComponents.isEmpty, !isWorking else { return false }
        return storageMode == .appInternal || folder != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let preview {
                    Section("Project") {
                        TextField("Name", text: Binding(get: { preview.projectName },
                                                       set: { self.preview?.projectName = $0 }))
                        LabeledContent("Files", value: preview.fileCount.formatted())
                        LabeledContent("Size", value: preview.totalBytes.formattedBytes)
                        if let recipe = preview.recipe {
                            LabeledContent("Linux Base", value: "\(recipe.base.distribution) \(recipe.base.release)")
                            LabeledContent("Tools", value: recipe.toolchains.map(\.id).formatted(.list(type: .and)))
                        }
                    }
                    if !preview.missingComponents.isEmpty {
                        Section {
                            ForEach(preview.missingComponents, id: \.self) {
                                Label($0, systemImage: "exclamationmark.triangle")
                            }
                        } header: {
                            Text("Not Available")
                        } footer: {
                            Text("The package needs components this catalog does not offer. Update the catalog and try again.")
                        }
                        .foregroundStyle(.orange)
                    }
                    Section {
                        Picker("Location", selection: $storageMode) {
                            Text("Only in Runfern").tag(StorageMode.appInternal)
                            Text("Folder in Files").tag(StorageMode.localFolder)
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
                        Text("All files were verified against the package’s checksum list. A Linux environment is set up from the recipe after importing.")
                    }
                } else if !pickingArchive {
                    ContentUnavailableView("No Package Selected", systemImage: "shippingbox",
                                           description: Text("Choose a Runfern project package (.zip)."))
                    Button("Choose Package…") { pickingArchive = true }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Import Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if let preview { ProjectImporter.discard(preview) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking { ProgressView() } else { Button("Import", action: commit).disabled(!canImport) }
                }
            }
            .fileImporter(isPresented: $pickingArchive, allowedContentTypes: [.zip]) { result in
                switch result {
                case .success(let url): prepare(url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                do {
                    folder = try WorkspaceAccess.makeBinding(for: result.get())
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func prepare(_ url: URL) {
        isWorking = true
        errorMessage = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ProjectImporter.Preview, Error> in
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                return Result { try ProjectImporter.prepare(archive: url) }
            }.value
            switch result {
            case .success(let prepared): preview = prepared
            case .failure(let error): errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func commit() {
        guard let preview else { return }
        let binding = storageMode == .appInternal ? WorkspaceBinding.appInternal() : folder
        guard let binding else { return }
        do {
            let project = try ProjectImporter.commit(preview, store: store, binding: binding)
            provisioner.start(project)
            onImported(project)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
