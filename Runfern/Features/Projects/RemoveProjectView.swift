import SwiftUI

/// Controlled removal: shows exactly what is deleted and what is kept.
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
        // Until the stored sync state has loaded, a synced project may hold unsynced changes.
        let losesData = onlyInApp || status?.hasUnsyncedData == true
            || (binding?.storageMode == .localFolder && !sync.hasLoaded)

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
                if losesData {
                    Section {
                        if let status, status.hasUnsyncedData {
                            StatusLabel("\(status.pendingLocalChanges) changes and \(status.conflicts.count) conflicts are not in the project folder yet.")
                            if let binding {
                                Button("Sync First") { Task { await sync.sync(binding) } }
                            }
                        }
                        Button("Export First…") { showingExport = true }
                        Toggle("Delete Data Anyway", isOn: $acknowledgedDataLoss)
                    } header: {
                        Text("Warning")
                    }
                }
            }
            // Removal keeps going once started, so nothing here may change meanwhile (A3).
            .disabled(isRemoving)
            .navigationTitle("Remove “\(project.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Stopping the environment can take seconds, and removal carries on regardless (A3).
                    CancelButton().disabled(isRemoving)
                }
                ToolbarItem(placement: .destructiveAction) {
                    if isRemoving {
                        ProgressView()
                    } else {
                        Button("Remove", role: .destructive) { remove() }
                            .disabled(losesData && !acknowledgedDataLoss)
                    }
                }
            }
            .interactiveDismissDisabled(isRemoving)
            .errorAlert("Couldn’t Remove Project", message: $errorMessage)
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
                sync.forgetStatus(for: project.workspaceBindingId)
                store.remove(project)
            }
            await IDEWebViewCache.shared.removeData(for: project.id)
        }
    }
}
