import SwiftUI

/// Storage use by shared bases, environments, and working copies.
struct StorageOverviewView: View {
    nonisolated struct Usage {
        var images: Int64 = 0
        var downloads: Int64 = 0
        var environments: [UUID: Int64] = [:]
        var workspaces: [UUID: Int64] = [:]
        var available: Int64 = 0
        var total: Int64 { images + downloads + environments.values.reduce(0, +) + workspaces.values.reduce(0, +) }
    }

    @Environment(ProjectStore.self) private var store
    @State private var usage: Usage?
    @State private var cleanupResult: String?
    @State private var isCleaning = false
    @State private var isConfirmingCleanup = false

    var body: some View {
        Form {
            if let usage {
                Section {
                    LabeledContent("Runfern Total", value: usage.total.formattedBytes)
                    LabeledContent("Free on iPad", value: usage.available.formattedBytes)
                }
                Section {
                    LabeledContent("Linux Bases", value: usage.images.formattedBytes)
                    LabeledContent("Interrupted Downloads", value: usage.downloads.formattedBytes)
                } header: {
                    Text("Shared")
                } footer: {
                    Text("A base is counted only once, even if several projects use it.")
                }
                if !store.snapshot.projects.isEmpty {
                    Section("Per Project") {
                        ForEach(store.snapshot.projects) { project in
                            let env = usage.environments[project.environmentId] ?? 0
                            let files = usage.workspaces[project.workspaceBindingId] ?? 0
                            // The total trails; the breakdown is the subtitle, so the name keeps its room.
                            LabeledContent {
                                Text((env + files).formattedBytes)
                            } label: {
                                Text(project.name)
                                Text("Environment \(env.formattedBytes) · Files \(files.formattedBytes)")
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        Button("Remove Unneeded Data", role: .destructive) { isConfirmingCleanup = true }
                            .disabled(isCleaning)
                            // On the button, so on iPad the dialog points at it.
                            .confirmationDialog("Remove Unneeded Data?", isPresented: $isConfirmingCleanup,
                                                titleVisibility: .visible) {
                                Button("Remove Data", role: .destructive, action: cleanUp)
                            } message: {
                                Text("Linux bases that no project uses are removed too. They must be downloaded again before an offline setup.")
                            }
                        if isCleaning {
                            Spacer()
                            ProgressView()
                        }
                    }
                    if let cleanupResult { Text(cleanupResult).foregroundStyle(.secondary) }
                } footer: {
                    Text("Removes unused Linux bases, interrupted downloads, and leftovers of removed projects.")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Storage Usage")
        .task { await measure() }
    }

    private func measure() async {
        let projects = store.snapshot.projects
        usage = await Task.detached(priority: .utility) {
            var usage = Usage()
            usage.images = DiskUsage.allocatedSize(of: AppPaths.images)
            usage.downloads = DiskUsage.allocatedSize(of: AppPaths.downloads)
            for project in projects {
                usage.environments[project.environmentId] = DiskUsage.allocatedSize(of: AppPaths.environment(project.environmentId))
                usage.workspaces[project.workspaceBindingId] = DiskUsage.allocatedSize(of: AppPaths.workspaceRoot(project.workspaceBindingId))
            }
            usage.available = DiskUsage.availableCapacity
            return usage
        }.value
    }

    /// Cleanup with safeguards: nothing referenced and no pending project changes.
    /// What to remove is listed on main (three small directories, cheap), so a project created
    /// meanwhile in another window is never touched. Measuring and deleting run detached (A10).
    private func cleanUp() {
        isCleaning = true
        cleanupResult = nil
        let referenced = store.referencedImageDirectories
        let knownEnvironments = Set(store.snapshot.environments.map(\.id.uuidString))
        let knownWorkspaces = Set(store.snapshot.bindings.map(\.id.uuidString))
        func entries(_ directory: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }
        let images = entries(AppPaths.images).filter { !referenced.contains($0.lastPathComponent) }
        // Partial downloads are named like the image directory they become.
        let partials = entries(AppPaths.downloads).filter { !referenced.contains($0.deletingPathExtension().lastPathComponent) }
        let orphans = entries(AppPaths.environments).filter { !knownEnvironments.contains($0.lastPathComponent) }
            + entries(AppPaths.workspaces).filter { !knownWorkspaces.contains($0.lastPathComponent) }
        Task {
            let freed = await Task.detached(priority: .userInitiated) { () -> Int64 in
                let fm = FileManager.default
                var freed: Int64 = 0
                for url in images {
                    freed += DiskUsage.allocatedSize(of: url)
                    try? ImageBundle.remove(url)
                }
                for url in partials + orphans {
                    freed += DiskUsage.allocatedSize(of: url)
                    try? fm.removeItem(at: url)
                }
                try? fm.removeItem(at: AppPaths.exports)
                return freed
            }.value
            cleanupResult = String(localized: "\(freed.formattedBytes) freed.")
            isCleaning = false
            await measure()
        }
    }
}
