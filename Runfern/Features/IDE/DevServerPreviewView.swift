import SwiftUI

/// Preview of a development server running in the active environment (IDE09).
/// Only ports the person forwards explicitly are reachable, and only from this device.
struct DevServerPreviewView: View {
    @Environment(RuntimeCoordinator.self) private var runtime
    @Environment(\.dismiss) private var dismiss

    @AppStorage("lastPreviewPort") private var portText = "3000"
    @State private var previewURL: URL?
    @State private var errorMessage: String?
    @State private var isForwarding = false

    var body: some View {
        NavigationStack {
            Group {
                if let previewURL {
                    LocalWebView(endpoint: IDEEndpoint(url: previewURL, sessionToken: "")) {
                        errorMessage = String(localized: "The development server is not responding. Is it running in the terminal?")
                    }
                    .safeAreaInset(edge: .bottom) {
                        if let errorMessage { Banner(text: LocalizedStringKey(errorMessage), systemImage: "exclamationmark.triangle", tint: .orange) }
                    }
                } else {
                    Form {
                        Section {
                            TextField("Port", text: $portText)
                                .keyboardType(.numberPad)
                            Button("Open Preview", action: forward)
                                .disabled(isForwarding || Int(portText) == nil)
                            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                        } footer: {
                            Text("Start your development server in the terminal, then enter its port. The server stays reachable only on this iPad and only for the running environment.")
                        }
                        if let ports = runtime.session?.previewPorts, !ports.isEmpty {
                            Section("Forwarded Ports") {
                                ForEach(ports.keys.sorted(), id: \.self) { port in
                                    Button("Port \(port.formatted(.number.grouping(.never)))") {
                                        portText = String(port)
                                        forward()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if previewURL != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Change Port", systemImage: "arrow.left.arrow.right") {
                            previewURL = nil
                            errorMessage = nil
                        }
                    }
                }
            }
            // A new session (stop or project switch) invalidates the preview immediately.
            .onChange(of: runtime.session?.generation) { dismiss() }
        }
    }

    private func forward() {
        guard let port = Int(portText) else { return }
        isForwarding = true
        errorMessage = nil
        Task {
            do {
                previewURL = try await runtime.preview(port: port)
            } catch {
                errorMessage = error.localizedDescription
            }
            isForwarding = false
        }
    }
}
