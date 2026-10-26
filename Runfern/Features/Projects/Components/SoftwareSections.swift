import SwiftUI

/// Tools and VS Code extensions of an environment, edited the same way everywhere: new projects,
/// presets, and the installed software of an existing project.
///
/// Selecting a tool also selects the extensions it suggests; each of them can be turned off.
/// Further extensions come from Open VSX and are named `publisher.name`.
struct SoftwareSections: View {
    let base: BaseImage?
    @Binding var selection: SoftwareSelection
    /// Tools and extensions can't change, for example while the environment runs; the editor can.
    var softwareLocked = false

    @State private var browsing = false

    private var tools: [ToolchainProfile] { base.map(Catalog.toolchains(for:)) ?? [] }

    var body: some View {
        Section {
            Toggle(isOn: $selection.touchOptimized) {
                Label("Touch Optimization", systemImage: "hand.tap")
            }
        } header: {
            Text("Editor")
        }

        Section("Tools") {
            ForEach(tools) { tool in
                Toggle(isOn: Binding(get: { selection.toolchainIds.contains(tool.id) },
                                     set: { selection.setTool(tool.id, selected: $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                        Text("\(tool.summary) · \(tool.estimatedSizeBytes.formattedBytes)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(softwareLocked)

        Section {
            ForEach(selection.suggestedExtensions, id: \.self) { id in
                extensionToggle(id, source: tools.first { $0.extensions.contains(id) && selection.toolchainIds.contains($0.id) }?.name)
            }
            ForEach(selection.customExtensions, id: \.self) { id in
                extensionToggle(id, source: nil)
            }
            // The sheet belongs to the button alone: on a section it would apply to every row, and
            // rows updating with loaded extension details dismissed it again.
            Button("Browse Extensions…", systemImage: "magnifyingglass") { browsing = true }
                .sheet(isPresented: $browsing) {
                    ExtensionBrowserView(selection: $selection)
                }
        } header: {
            Text("VS Code Extensions")
        } footer: {
            Text("From Open VSX.")
        }
        .disabled(softwareLocked)
    }

    private func extensionToggle(_ id: String, source: String?) -> some View {
        Toggle(isOn: Binding(get: { selection.extensions.contains(id) },
                             set: { selection.setExtension(id, selected: $0) })) {
            ExtensionLabel(id: id, source: source)
        }
    }
}

/// Icon, name, and origin of a selected extension, as in the extension browser. Without a
/// connection it shows the identifier only.
private struct ExtensionLabel: View {
    let id: String
    let source: String?

    /// Details survive reopening the page, so the list doesn't flicker or refetch.
    private static var cache: [String: OpenVSXClient.Details] = [:]

    @State private var details: OpenVSXClient.Details?

    var body: some View {
        HStack(spacing: 12) {
            ExtensionIcon(url: details?.files?.icon, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(details?.displayName ?? id)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: id) {
            if let cached = Self.cache[id] {
                details = cached
            } else if let loaded = try? await OpenVSXClient().details(of: id) {
                Self.cache[id] = loaded
                details = loaded
            }
        }
    }

    private var subtitle: String {
        if let source { String(localized: "Suggested by \(source)") } else { details?.namespace ?? id }
    }
}
