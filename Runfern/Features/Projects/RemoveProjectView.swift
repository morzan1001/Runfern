import SwiftUI

/// Controlled removal (PRJ06, Plan 2.6): shows exactly what is deleted and what is kept.
struct RemoveProjectView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SyncCenter.self) private var sync
    @Environment(RuntimeCoordinator.self) private var runtime
    @Environment(Provisioner.self) private var provisioner
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let onRemoved: () -> Void

    @State private var acknowledgedDataLoss = false
    @State private var isRemoving = false
    @State private var showingExport = false
    @State private var errorMessage: String?

    var body: some View {
        let binding = store.binding(for: project)
        let status = binding.map { sync.status(for: $0) }
        let onlyInApp = binding?.storageMode == .appInternal
        let losesData = onlyInApp || status?.hasUnsyncedData == true

        NavigationStack {
            Form {
                Section("Will Be Deleted") {
                    Label("Linux environment with installed packages", systemImage: "shippingbox")
                    if onlyInApp {
                        Label("Project files (stored only in Runfern)", systemImage: "doc")
                    } else if binding?.storageMode == .localFolder {
                        Label("Local working copy in Runfern", systemImage: "doc")
                    }
                }
                Section("Will Be Kept") {
                    if let binding, binding.isInFiles {
                        Label("Project folder “\(binding.displayLocation)” in Files", systemImage: "folder")
                    }
                    Label("Shared Linux base images", systemImage: "square.stack.3d.up")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                if losesData {
                    Section {
                        if let status, status.hasUnsyncedData {
                            Label("\(status.pendingLocalChanges) changes and \(status.conflicts.count) conflicts are not in the project folder yet.",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            if let binding {
                                Button("Sync First") { Task { await sync.sync(binding) } }
                            }
                        }
                        Button("Export First…") { showingExport = true }
                        Toggle("Delete this data anyway", isOn: $acknowledgedDataLoss)
                    } header: {
                        Text("Warning")
                    }
                }
            }
            .navigationTitle("Remove “\(project.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove", role: .destructive) { remove() }
                        .disabled(isRemoving || (losesData && !acknowledgedDataLoss))
                }
            }
            .sheet(isPresented: $showingExport) { ExportView(project: project) }
        }
    }

    /// Linux must no longer use the environment's files, and the lists must stop showing the
    /// project before its data disappears; otherwise sidebar and detail update inconsistently.
    private func remove() {
        isRemoving = true
        errorMessage = nil
        Task {
            provisioner.cancel(project)
            if runtime.activeProjectID == project.id { await runtime.stopActiveProject() }
            guard runtime.activeProjectID != project.id else {
                errorMessage = String(localized: "The environment is still starting or stopping. Try again in a moment.")
                isRemoving = false
                return
            }
            onRemoved()
            dismiss()
            try? await Task.sleep(for: .milliseconds(400))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                sync.removeData(for: project.workspaceBindingId)
                store.remove(project)
            }
            await IDEWebViewCache.shared.removeData(for: project.id)
        }
    }
}
