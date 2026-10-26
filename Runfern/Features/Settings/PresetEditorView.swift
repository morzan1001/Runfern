import SwiftUI

/// Edits one environment preset: base, tools, VS Code extensions, VS Code settings, and resources.
struct PresetEditorView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var preset: EnvironmentPreset
    @State private var settingsText: String
    @State private var settingsError: String?

    init(preset: EnvironmentPreset) {
        _preset = State(initialValue: preset)
        _settingsText = State(initialValue: preset.editorSettings ?? "")
    }

    private var base: BaseImage? { Catalog.baseImage(id: preset.baseImageId) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $preset.name)
                }

                Section("Environment") {
                    Picker("Distribution", selection: $preset.baseImageId) {
                        ForEach(Catalog.baseImages) { Text($0.displayName).tag($0.id) }
                    }
                    SoftwareLink(base: base, selection: $preset.software)
                    Picker("Resources", selection: $preset.resources) {
                        ForEach(ResourceProfile.allCases, id: \.self) { profile in
                            Text("\(profile.title) – \(profile.memoryMB / 1024) GB, \(profile.cpuCount) CPUs").tag(profile)
                        }
                    }
                }

                Section {
                    TextEditor(text: $settingsText)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 160)
                    if let settingsError {
                        Label(settingsError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("VS Code Settings")
                } footer: {
                    Text("Contents of settings.json, for example {\"editor.fontSize\": 16}.")
                }
            }
            .navigationTitle(preset.name.isEmpty ? String(localized: "New Preset") : preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm, action: save)
                        .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: preset.baseImageId) {
                // Only combinations listed in the catalog are offered (IMG03).
                let supported = base?.supportedToolchains ?? []
                preset.toolchainIds.removeAll { !supported.contains($0) }
            }
        }
    }

    private func save() {
        do {
            try EnvironmentPreset.validateSettings(settingsText)
            let trimmed = settingsText.trimmingCharacters(in: .whitespacesAndNewlines)
            preset.editorSettings = trimmed.isEmpty ? nil : trimmed
            preset.name = preset.name.trimmingCharacters(in: .whitespaces)
            store.savePreset(preset)
            dismiss()
        } catch {
            settingsError = error.localizedDescription
        }
    }
}
