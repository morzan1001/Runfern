import SwiftUI

/// The person's own environment presets: create, edit, and delete.
struct PresetsView: View {
    @Environment(ProjectStore.self) private var store
    @State private var editing: EnvironmentPreset?

    var body: some View {
        List {
            if store.presets.isEmpty {
                ContentUnavailableView {
                    Label("No Presets", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Save tools, VS Code extensions, and VS Code settings once and reuse them for new projects.")
                } actions: {
                    Button("Create Preset") { editing = .blank }
                        .buttonStyle(.glassProminent)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(store.presets) { preset in
                Button {
                    editing = preset
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.name).foregroundStyle(.primary)
                        Text(preset.summary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { store.presets[$0] }.forEach(store.removePreset)
            }
        }
        .navigationTitle("Presets")
        .toolbar {
            Button("New Preset", systemImage: "plus") { editing = .blank }
        }
        .sheet(item: $editing) { preset in
            PresetEditorView(preset: preset)
        }
    }
}

extension EnvironmentPreset {
    static var blank: EnvironmentPreset {
        EnvironmentPreset(id: UUID(), name: "", baseImageId: Catalog.baseImages.first?.id ?? "",
                          toolchainIds: [], extensionIds: [], resources: .standard, editorSettings: nil)
    }

    var summary: String {
        let base = Catalog.baseImage(id: baseImageId)?.displayName ?? baseImageId
        let tools = toolchainIds.compactMap { Catalog.toolchain(id: $0)?.name }
        var parts = [base] + tools
        if !extensionIds.isEmpty { parts.append(String(localized: "\(extensionIds.count) extensions")) }
        if editorSettings?.isEmpty == false { parts.append(String(localized: "VS Code settings")) }
        return parts.formatted(.list(type: .and, width: .narrow))
    }
}
