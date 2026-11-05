import SwiftUI

/// Global settings, storage overview, and help.
/// Project configuration lives in the project detail view, IDE settings in the IDE itself.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CatalogStore.self) private var catalog
    @Environment(Connectivity.self) private var connectivity
    @AppStorage("downloadsOnlyOnWiFi") private var downloadsOnlyOnWiFi = true
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $downloadsOnlyOnWiFi) {
                        Label("Large Downloads over Wi-Fi Only", systemImage: "wifi")
                    }
                }

                Section("Projects") {
                    NavigationLink { PresetsView() } label: { Label("Presets", systemImage: "square.stack.3d.up") }
                    NavigationLink { CredentialsView() } label: { Label("Git Credentials", systemImage: "key") }
                }

                Section {
                    NavigationLink { BaseImagesView() } label: { Label("Linux Bases", systemImage: "shippingbox") }
                    NavigationLink { StorageOverviewView() } label: { Label("Storage Usage", systemImage: "internaldrive") }
                    LabeledContent("Catalog", value: catalog.publishedAt.formatted(date: .abbreviated, time: .omitted))
                    // Only offered once a catalog source is published.
                    if CatalogStore.updateURL != nil {
                        Button {
                            Task { await catalog.checkForUpdate(isOnline: connectivity.isOnline) }
                        } label: {
                            HStack {
                                Label("Check for Catalog Update", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if catalog.isChecking {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(catalog.isChecking || !connectivity.isOnline)
                    }
                    if let error = catalog.lastError {
                        StatusLabel(error, tint: .red)
                    }
                } header: {
                    Text("Linux")
                } footer: {
                    if CatalogStore.updateURL != nil, !connectivity.isOnline {
                        Text("Checking for updates needs an internet connection.")
                    }
                }

                #if RUNFERN_JIT
                JITSection()
                #endif

                DeviceProfileSection(profile: .current)

                Section("Help") {
                    NavigationLink { HelpView() } label: { Label("How Runfern Works", systemImage: "questionmark.circle") }
                    Button {
                        dismiss()
                        didCompleteOnboarding = false
                    } label: {
                        Label("Show Introduction Again", systemImage: "sparkles")
                    }
                }

                Section {
                    NavigationLink { ComponentsView() } label: { Label("Components and Licenses", systemImage: "doc.text") }
                    NavigationLink { DiagnosticsView() } label: { Label("Diagnostics", systemImage: "stethoscope") }
                    LabeledContent("Version", value: AppVersion.display)
                } header: {
                    Text("About")
                } footer: {
                    Text("Runfern does not transmit source code, project files, or diagnostic data.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}
