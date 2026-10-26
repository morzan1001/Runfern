import SwiftUI

/// One project in the sidebar: a state-colored icon, the name, and what it is built on.
struct ProjectRow: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SyncCenter.self) private var sync
    let project: Project
    let isActive: Bool

    var body: some View {
        let env = store.environment(for: project)
        let image = env.flatMap { Catalog.baseImage(id: $0.baseImageId) }
        let binding = store.binding(for: project)
        let state = env?.state ?? .stopped

        HStack(spacing: 12) {
            Image(systemName: isActive ? "play.fill" : "chevron.left.forwardslash.chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(isActive ? .white : state.tint)
                .frame(width: 36, height: 36)
                .background(isActive ? AnyShapeStyle(.green) : AnyShapeStyle(state.tint.opacity(0.15)),
                            in: .rect(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                let summary = [image?.displayName] + (env?.toolchainIds.map { Catalog.toolchain(id: $0)?.name } ?? [])
                Text(summary.compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let binding {
                    // One fact per row: what needs attention, otherwise where the files are.
                    Group {
                        if binding.accessState == .unavailable {
                            Label("Not Reachable", systemImage: "exclamationmark.triangle")
                        } else if sync.status(for: binding).hasUnsyncedData {
                            Label("Pending", systemImage: "arrow.triangle.2.circlepath")
                        } else if isActive {
                            Label("Active", systemImage: "play.circle")
                        } else if state != .ready && state != .stopped {
                            Label(state.title, systemImage: state.systemImage)
                        } else {
                            Label(binding.displayLocation, systemImage: binding.storageMode == .appInternal ? "ipad" : "folder")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
