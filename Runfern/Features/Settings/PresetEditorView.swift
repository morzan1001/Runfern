import SwiftUI

/// Edits one environment preset: base, tools, VS Code extensions, VS Code settings, and resources.
struct PresetEditorView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(ImageLibrary.self) private var images
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    @State private var preset: EnvironmentPreset
    @State private var settingsText: String
    @State private var settingsError: String?
    /// Set when Save adds a new preset, so the title doesn't switch to "Edit Preset" while the sheet closes.
    @State private var savedAsNew = false
    private let original: EnvironmentPreset

    init(preset: EnvironmentPreset) {
        original = preset
        _preset = State(initialValue: preset)
        _settingsText = State(initialValue: preset.editorSettings ?? "")
    }

    private var base: BaseImage? { catalog.baseImages.first { $0.id == preset.baseImageId } }

    /// Edits that Cancel or a swipe down would throw away (A2). A blank new preset closes without asking.
    private var hasChanges: Bool {
        preset != original || settingsText != (original.editorSettings ?? "")
    }

    private var isNew: Bool {
        savedAsNew || !store.presets.contains { $0.id == preset.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $preset.name)
                }

                Section {
                    BaseImagePicker(selection: $preset.baseImageId)
                    SoftwareLink(base: base, selection: $preset.software)
                    Picker("Resources", selection: $preset.resources) {
                        ForEach(ResourceProfile.allCases, id: \.self) { profile in
                            // Same as the project screen: only profiles this iPad can run (ProjectDetailView).
                            Text("\(profile.title) – \(profile.memoryMB / 1024) GB, \(profile.cpuCount) CPUs")
                                .tag(profile)
                                .selectionDisabled(!profile.isSupported())
                        }
                    }
                } header: {
                    Text("Environment")
                } footer: {
                    // A preset kept from an earlier catalog, or made in the simulator.
                    if let base, !images.isOffered(base) {
                        StatusLabel("\(base.displayName) is not available for download yet.")
                    }
                }

                Section {
                    TextEditor(text: $settingsText)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 160)
                        .accessibilityLabel("VS Code Settings")
                    if let settingsError {
                        StatusLabel(settingsError, tint: .red)
                            .font(.footnote)
                    }
                } header: {
                    Text("VS Code Settings")
                } footer: {
                    Text("Contents of settings.json, for example {\"editor.fontSize\": 16}.")
                }
            }
            .navigationTitle(isNew ? Text("New Preset") : Text("Edit Preset"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: hasChanges)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm, action: save)
                        .keyboardShortcut(.return, modifiers: .command)
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
            savedAsNew = isNew
            store.savePreset(preset)
            dismiss()
        } catch {
            settingsError = error.localizedDescription
        }
    }
}
