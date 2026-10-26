import SwiftUI

/// Export of source code and environment recipe (DAT05). Shows scope and exclusions up front.
struct ExportView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let project: Project

    @State private var preview: ProjectExporter.Preview?
    @State private var archive: URL?
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var movingArchive = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Contents") {
                    if let preview {
                        LabeledContent("Files", value: preview.fileCount.formatted())
                        LabeledContent("Size", value: preview.totalBytes.formattedBytes)
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
                    Label("Secrets you stored in project files yourself (such as .env) are included.",
                          systemImage: "key")
                        .foregroundStyle(.orange)
                } header: {
                    Text("Scope")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button("Create Archive", action: export).disabled(preview == nil)
                    }
                }
            }
            .task { await loadPreview() }
            .fileMover(isPresented: $movingArchive, file: archive) { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription } else { dismiss() }
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
            errorMessage = error.localizedDescription
        }
    }

    private func export() {
        let name = project.name
        let recipe = store.environment(for: project).flatMap(Catalog.recipe(for:))
        isExporting = true
        errorMessage = nil
        Task {
            do {
                let files = try projectFiles()
                archive = try await Task.detached(priority: .userInitiated) {
                    try ProjectExporter.export(projectName: name, workingCopy: files.url, recipe: recipe)
                }.value
                movingArchive = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}
