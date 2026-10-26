import SwiftUI
import WebKit

/// Details of one Open VSX extension with its README, like the extension page in VS Code.
struct ExtensionDetailView: View {
    let id: String
    @Binding var selection: SoftwareSelection

    @State private var details: OpenVSXClient.Details?
    @State private var readme: String?
    @State private var errorMessage: String?

    private var isAdded: Bool { selection.extensions.contains(id) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            if let readme {
                ReadmeView(html: MarkdownHTML.document(readme, baseURL: details?.files?.readme))
            } else if let errorMessage {
                ContentUnavailableView("README Not Available", systemImage: "doc.text", description: Text(errorMessage))
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(details?.displayName ?? id)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ExtensionIcon(url: details?.files?.icon)
                .scaleEffect(1.4)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(details?.displayName ?? id).font(.title2.weight(.semibold))
                HStack(spacing: 4) {
                    Text(details?.namespace ?? "")
                    if details?.verified == true {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
                            .accessibilityLabel("Verified publisher")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let description = details?.description {
                    Text(description).font(.subheadline)
                }
                Text(facts).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if isAdded {
                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                    selection.setExtension(id, selected: false)
                }
                .buttonStyle(.glass)
            } else {
                Button("Add", systemImage: "plus") { selection.setExtension(id, selected: true) }
                    .buttonStyle(.glassProminent)
                    .foregroundStyle(.white)
            }
        }
    }

    private var facts: String {
        var parts: [String] = [id]
        if let version = details?.version { parts.append(version) }
        if let license = details?.license { parts.append(license) }
        if let downloads = details?.downloadCount {
            parts.append(String(localized: "\(downloads.formatted(.number.notation(.compactName))) downloads"))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            let loaded = try await OpenVSXClient().details(of: id)
            details = loaded
            guard let url = loaded.files?.readme else {
                errorMessage = String(localized: "This extension has no README.")
                return
            }
            readme = try await OpenVSXClient().readme(at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Shows README HTML; links open outside the app instead of navigating inside it.
private struct ReadmeView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            await UIApplication.shared.open(url)
            return .cancel
        }
    }
}

#Preview {
    @Previewable @State var selection = SoftwareSelection(toolchainIds: ["python-3"])
    NavigationStack { ExtensionDetailView(id: "esbenp.prettier-vscode", selection: $selection) }
}
