import SwiftUI
import WebKit

/// Hosts the session's cached editor web view (see `IDEWebViewCache`). Only the local endpoint of
/// the active session may be loaded (Plan 4.8).
struct IDEWebView: UIViewRepresentable {
    let endpoint: IDEEndpoint
    let projectID: UUID
    var touchOptimized = false
    let actions: EditorActions
    let onConnectionLost: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(endpoint: endpoint, actions: actions, onConnectionLost: onConnectionLost)
    }

    func makeUIView(context: Context) -> UIView {
        let container = Container()
        attach(to: container, coordinator: context.coordinator)
        return container
    }

    /// Reports its width, which the touch adaptations scale VS Code against.
    final class Container: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            IDEWebViewCache.shared.editorDidResize(width: bounds.width)
        }
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.endpoint = endpoint
        context.coordinator.actions = actions
        attach(to: container, coordinator: context.coordinator)
    }

    /// Moves the cached view into this container; it may still sit in a container that is being torn down.
    private func attach(to container: UIView, coordinator: Coordinator) {
        // Before the view exists, so a new one loads in the matching content mode right away.
        IDEWebViewCache.shared.setTouchOptimized(touchOptimized)
        let webView = IDEWebViewCache.shared.webView(for: endpoint, projectID: projectID)
        IDEWebViewCache.shared.actions = coordinator.actions
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var endpoint: IDEEndpoint
        var actions: EditorActions
        let onConnectionLost: () -> Void

        init(endpoint: IDEEndpoint, actions: EditorActions, onConnectionLost: @escaping () -> Void) {
            self.endpoint = endpoint
            self.actions = actions
            self.onConnectionLost = onConnectionLost
        }

        /// VS Code opens external links in a new window; `runfern://` links come from the Runfern
        /// extension and become app actions. Other windows are never opened.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { actions.perform(url) }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if actions.perform(url) { return .cancel }
            let sameOrigin = url.host() == endpoint.url.host() && url.port == endpoint.url.port && url.scheme == endpoint.url.scheme
            return sameOrigin || url.scheme == "about" || url.scheme == "blob" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onConnectionLost()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onConnectionLost()
        }

        /// iPadOS may end the web content process while the app is in the background; VS Code then
        /// reloads and restores its state from the project's data store.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }
    }
}
