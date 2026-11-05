import SwiftUI

/// Export of source code and environment recipe. Shows scope and exclusions up front.
struct ExportView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let project: Project

    @State private var preview: ProjectExporter.Preview?
    @State private var archive: URL?
    @State private var isExporting = false
    /// The contents couldn't be read; shown in place of them (A7).
    @State private var previewError: String?
    /// Creating or saving the archive failed; shown as an alert (A7).
    @State private var exportError: String?
    @State private var movingArchive = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Contents") {
                    if let preview {
                        LabeledContent("Files", value: preview.fileCount.formatted())
                        LabeledContent("Size", value: preview.totalBytes.formattedBytes)
                    } else if let previewError {
                        StatusLabel(previewError, tint: .red)
                    } else {
                        ProgressView()
                    }
                    Label("Project files", systemImage: "doc.on.doc")
                    Label("Environment recipe (Linux base and toolchain profiles)", systemImage: "list.bullet.rectangle")
                    Label("Checksum list for verification", systemImage: "checkmark.seal")
                }
                Section {
                    Text("Not included: Linux system data, installed packages, and app-managed credentials. Rebuilding from the recipe may require downloads.")
                    if let preview {
                        Text("Excluded: \(preview.excludedNames.formatted(.list(type: .and)))")
                    }
                    StatusLabel("Secrets you stored in project files yourself (such as .env) are included.",
                                systemImage: "key")
                } header: {
                    Text("Scope")
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // The archive is written in the background and can't be stopped halfway (A3).
                    CancelButton().disabled(isExporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button("Create Archive", role: .confirm, action: export)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(preview == nil)
                    }
                }
            }
            .interactiveDismissDisabled(isExporting)
            .errorAlert("Couldn’t Export Project", message: $exportError)
            .task { await loadPreview() }
            .fileMover(isPresented: $movingArchive, file: archive) { result in
                if case .failure(let error) = result { exportError = error.localizedDescription } else { dismiss() }
            }
        }
    }

    private func projectFiles() throws -> WorkspaceFiles {
        guard let binding = store.binding(for: project) else { throw WorkspaceAccess.AccessError.unavailable }
        return try WorkspaceFiles(binding)
    }

    private func loadPreview() async {
        do {
            let files = try projectFiles()
            preview = try await Task.detached { try ProjectExporter.preview(workingCopy: files.url) }.value
        } catch {
            previewError = error.localizedDescription
        }
    }

    private func export() {
        let name = project.name
        let recipe = store.environment(for: project).flatMap(Catalog.recipe(for:))
        isExporting = true
        exportError = nil
        Task {
            do {
                let files = try projectFiles()
                archive = try await Task.detached(priority: .userInitiated) {
                    try ProjectExporter.export(projectName: name, workingCopy: files.url, recipe: recipe)
                }.value
                movingArchive = true
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }
}
