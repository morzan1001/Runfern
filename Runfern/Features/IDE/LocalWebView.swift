import SwiftUI
import WebKit

/// A load replaced by another one, or stopped by a policy decision: not an error to show.
func isCancelledNavigation(_ error: Error) -> Bool {
    let error = error as NSError
    return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
        || (error.domain == "WebKitErrorDomain" && error.code == 102)
}

/// Restricted web view: only allows navigation to the local endpoint of the active session.
struct LocalWebView: UIViewRepresentable {
    let endpoint: IDEEndpoint
    /// Each change reloads the page.
    var reloadToken = 0
    var onLoadingChange: (Bool) -> Void = { _ in }
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
        context.coordinator.request = request
        context.coordinator.lastToken = reloadToken
        context.coordinator.onLoadingChange = onLoadingChange
        view.load(request)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onLoadingChange = onLoadingChange
        guard reloadToken != context.coordinator.lastToken else { return }
        context.coordinator.lastToken = reloadToken
        // Reload keeps cookies and storage of the app under test; load() if nothing was ever committed.
        if uiView.url == nil { uiView.load(context.coordinator.request) } else { uiView.reload() }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let endpoint: IDEEndpoint
        let onConnectionLost: () -> Void
        var onLoadingChange: (Bool) -> Void = { _ in }
        var request: URLRequest
        var lastToken = 0

        init(endpoint: IDEEndpoint, onConnectionLost: @escaping () -> Void) {
            self.endpoint = endpoint
            self.onConnectionLost = onConnectionLost
            self.request = URLRequest(url: endpoint.url)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            let sameOrigin = url.host() == endpoint.url.host() && url.port == endpoint.url.port && url.scheme == endpoint.url.scheme
            return sameOrigin || url.scheme == "about" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChange(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChange(false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
            guard !isCancelledNavigation(error) else { return }
            onConnectionLost()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
            guard !isCancelledNavigation(error) else { return }
            onConnectionLost()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }
    }
}
