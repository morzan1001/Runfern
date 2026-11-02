import SwiftUI

/// Languages and VS Code extensions of an environment, edited the same way everywhere: new projects,
/// presets, and the installed software of an existing project.
///
/// Languages are chosen on a pushed page with checkmarks and can also be swiped away here. Selecting a
/// language also selects the extensions it suggests; each of them can be turned off. Further
/// extensions come from Open VSX, also on a pushed page, are named `publisher.name`, and are
/// swiped away here. The host must provide the `NavigationStack`.
struct SoftwareSections: View {
    let base: BaseImage?
    @Binding var selection: SoftwareSelection
    /// Languages and extensions can't change, for example while the environment runs; the editor can.
    var softwareLocked = false

    private var tools: [ToolchainProfile] { base.map(Catalog.toolchains(for:)) ?? [] }
    private var families: [ToolchainFamily] { base.map(Catalog.toolchainFamilies(for:)) ?? [] }

    var body: some View {
        Section {
            Toggle(isOn: $selection.touchOptimized) {
                Label("Touch Optimization", systemImage: "hand.tap")
            }
        } header: {
            Text("Editor")
        } footer: {
            Text("More spacing, wider scroll bars, word wrap, and a key bar above the on-screen keyboard.")
        }

        Section("Languages") {
            ForEach(selection.toolchains) { tool in
                toolRow(tool)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) { removeToolButton(tool) }
                    .contextMenu { if !softwareLocked { removeToolButton(tool) } }
            }
            NavigationLink {
                ToolchainCatalogView(base: base, selection: $selection)
            } label: {
                Label("Choose Languages", systemImage: "plus")
            }
        }
        .disabled(softwareLocked)

        Section {
            ForEach(selection.suggestedExtensions, id: \.self) { id in
                extensionToggle(id, source: tools.first { $0.extensions.contains(id) && selection.toolchainIds.contains($0.id) }?.name)
            }
            // Added by hand, so removed by hand: a switch would make the row disappear.
            ForEach(selection.additionalExtensions, id: \.self) { id in
                ExtensionLabel(id: id, source: nil)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) { removeExtensionButton(id) }
                    .contextMenu { if !softwareLocked { removeExtensionButton(id) } }
            }
            NavigationLink {
                ExtensionBrowserView(selection: $selection)
            } label: {
                Label("Browse Extensions", systemImage: "magnifyingglass")
            }
        } header: {
            Text("VS Code Extensions")
        } footer: {
            Text("From Open VSX.")
        }
        .disabled(softwareLocked)
    }

    /// A chosen language: its version can be changed in place; swiping or the language list removes it.
    /// The row content is the control's label, so VoiceOver names the language with its version.
    @ViewBuilder
    private func toolRow(_ tool: ToolchainProfile) -> some View {
        let family = families.first { $0.id == tool.family }
        if let family, family.versions.count > 1 {
            Picker(selection: Binding(get: { tool.id }, set: { selection.setTool($0, selected: true) })) {
                ForEach(family.versions) { Text($0.version).tag($0.id) }
            } label: {
                toolLabel(tool)
            }
        } else {
            LabeledContent {
                Text(tool.version)
            } label: {
                toolLabel(tool)
            }
        }
    }

    private func toolLabel(_ tool: ToolchainProfile) -> some View {
        HStack(spacing: 12) {
            ToolchainIcon(family: tool.family, name: tool.familyName)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.familyName)
                Text("\(tool.summary) · \(tool.estimatedSizeBytes.formattedBytes)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func removeToolButton(_ tool: ToolchainProfile) -> some View {
        Button("Remove", systemImage: "trash", role: .destructive) {
            withAnimation { selection.setTool(tool.id, selected: false) }
        }
    }

    private func removeExtensionButton(_ id: String) -> some View {
        Button("Remove", systemImage: "trash", role: .destructive) {
            withAnimation { selection.setExtension(id, selected: false) }
        }
    }

    /// A suggested extension: it stays in the list when turned off, so it can be turned on again.
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
