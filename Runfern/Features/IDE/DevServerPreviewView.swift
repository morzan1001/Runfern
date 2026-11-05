import SwiftUI

/// Preview of a development server running in the active environment.
/// Only ports the person forwards explicitly are reachable, and only from this device.
struct DevServerPreviewView: View {
    @Environment(RuntimeCoordinator.self) private var runtime
    @Environment(\.dismiss) private var dismiss

    @AppStorage("lastPreviewPort") private var portText = "3000"
    /// The forwarded page; pushed on top of the port form.
    @State private var target: PreviewTarget?
    @State private var errorMessage: String?
    @State private var pageError: String?
    @State private var isForwarding = false
    @State private var isLoading = true
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Port") {
                        TextField("Port", text: $portText, prompt: Text(verbatim: "3000"))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.go)
                            .onSubmit { forward() }
                    }
                    Button(action: forward) {
                        HStack {
                            Text("Open Preview")
                            Spacer()
                            if isForwarding { ProgressView() }
                        }
                    }
                    .disabled(isForwarding || Int(portText) == nil)
                    if let errorMessage { StatusLabel(errorMessage, tint: .red) }
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
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .navigationDestination(item: $target) { target in
                page(for: target)
            }
            .onChange(of: target) {
                if target == nil { pageError = nil }
            }
            // A new session (stop or project switch) invalidates the preview immediately.
            .onChange(of: runtime.session?.generation) { dismiss() }
        }
    }

    /// The development server's page; Back returns to the port form.
    private func page(for target: PreviewTarget) -> some View {
        LocalWebView(endpoint: IDEEndpoint(url: target.url, sessionToken: ""), reloadToken: reloadToken,
                     onLoadingChange: { isLoading = $0 }) {
            pageError = String(localized: "The development server is not responding. Is it running in the terminal?")
        }
        .overlay {
            if isLoading { ProgressView() }
        }
        .safeAreaInset(edge: .bottom) {
            if let pageError { Banner(text: pageError, systemImage: "exclamationmark.triangle", tint: .orange) }
        }
        .navigationTitle("Port \(target.port.formatted(.number.grouping(.never)))")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reload", systemImage: "arrow.clockwise") {
                    pageError = nil
                    reloadToken += 1
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            // The form's Close does not carry over to a pushed page.
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .close) { dismiss() }
            }
        }
    }

    private func forward() {
        // The range check stays in RuntimeCoordinator.preview, which explains the allowed ports.
        guard !isForwarding, let port = Int(portText) else { return }
        isForwarding = true
        errorMessage = nil
        Task {
            do {
                let url = try await runtime.preview(port: port)
                isLoading = true
                target = PreviewTarget(port: port, url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
            isForwarding = false
        }
    }
}

/// The port the person asked for, and the local URL it is forwarded to.
private nonisolated struct PreviewTarget: Hashable, Sendable {
    let port: Int
    let url: URL
}
