import SwiftUI

/// Storage use by shared bases, environments, and working copies (DAT01).
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
    @Environment(ImageLibrary.self) private var images
    @State private var usage: Usage?
    @State private var cleanupResult: String?

    var body: some View {
        Form {
            if let usage {
                Section {
                    LabeledContent("Runfern Total", value: usage.total.formattedBytes)
                    LabeledContent("Free on iPad", value: usage.available.formattedBytes)
                }
                Section {
                    LabeledContent("Base Images", value: usage.images.formattedBytes)
                    LabeledContent("Interrupted Downloads", value: usage.downloads.formattedBytes)
                } header: {
                    Text("Shared")
                } footer: {
                    Text("A base is counted only once, even if several projects use it.")
                }
                Section("Per Project") {
                    ForEach(store.snapshot.projects) { project in
                        let env = usage.environments[project.environmentId] ?? 0
                        let files = usage.workspaces[project.workspaceBindingId] ?? 0
                        LabeledContent(project.name) {
                            Text("Environment \(env.formattedBytes) · Files \(files.formattedBytes)")
                        }
                    }
                }
                Section {
                    Button("Remove Unneeded Data", action: cleanUp)
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

    /// Cleanup with safeguards (DAT07): nothing referenced and no pending project changes.
    private func cleanUp() {
        var freed = images.removeUnreferenced(keeping: store.referencedImageDirectories)
        let knownEnvironments = Set(store.snapshot.environments.map(\.id.uuidString))
        let knownWorkspaces = Set(store.snapshot.bindings.map(\.id.uuidString))
        let fm = FileManager.default
        for (directory, known) in [(AppPaths.environments, knownEnvironments), (AppPaths.workspaces, knownWorkspaces)] {
            let entries = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where !known.contains(entry.lastPathComponent) {
                freed += DiskUsage.allocatedSize(of: entry)
                try? fm.removeItem(at: entry)
            }
        }
        try? fm.removeItem(at: AppPaths.exports)
        cleanupResult = String(localized: "\(freed.formattedBytes) freed.")
        Task { await measure() }
    }
}
