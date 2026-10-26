import SwiftUI
import WebKit

/// Restricted web view: only allows navigation to the local endpoint of the active session (Plan 4.8).
struct LocalWebView: UIViewRepresentable {
    let endpoint: IDEEndpoint
    let onConnectionLost: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(endpoint: endpoint, onConnectionLost: onConnectionLost)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Session-scoped data; nothing outlives the session inside the web view.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isInspectable = false
        var request = URLRequest(url: endpoint.url)
        // The IDE endpoint is token-protected; previews of development servers carry no token.
        if !endpoint.sessionToken.isEmpty {
            request.setValue("Bearer \(endpoint.sessionToken)", forHTTPHeaderField: "Authorization")
        }
        view.load(request)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let endpoint: IDEEndpoint
        let onConnectionLost: () -> Void

        init(endpoint: IDEEndpoint, onConnectionLost: @escaping () -> Void) {
            self.endpoint = endpoint
            self.onConnectionLost = onConnectionLost
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            let sameOrigin = url.host() == endpoint.url.host() && url.port == endpoint.url.port && url.scheme == endpoint.url.scheme
            return sameOrigin || url.scheme == "about" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onConnectionLost()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onConnectionLost()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }
    }
}
