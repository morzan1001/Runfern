import SwiftUI

/// Global settings (SET01, OFF05), storage overview (DAT01, DAT07), and help (SET03).
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

                Section("Linux") {
                    NavigationLink { BaseImagesView() } label: { Label("Linux Bases", systemImage: "shippingbox") }
                    NavigationLink { StorageOverviewView() } label: { Label("Storage Usage", systemImage: "internaldrive") }
                    // Only offered once a catalog source is published.
                    if CatalogStore.updateURL != nil {
                        Button {
                            Task { await catalog.checkForUpdate(isOnline: connectivity.isOnline) }
                        } label: {
                            Label("Check for Catalog Update", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(catalog.isChecking || !connectivity.isOnline)
                    }
                    if let error = catalog.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
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
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
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
                }
            }
        }
    }
}
