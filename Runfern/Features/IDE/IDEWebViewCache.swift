import WebKit

/// Keeps the editor's web view alive for the whole session, so leaving the editor and coming back
/// restores it exactly as it was instead of loading a new VS Code (RUN04).
///
/// Each project gets its own persistent website data store: VS Code keeps layout, open editors,
/// and backups of unsaved changes there across restarts. Nothing is shared between projects.
@MainActor
final class IDEWebViewCache {
    static let shared = IDEWebViewCache()

    private var entry: (endpointURL: URL, view: WKWebView)?
    private let bridge = BridgeHandler()
    private var touchOptimized = false
    private var width: Double = 0

    /// Actions of the editor currently on screen; messages from the web view are forwarded there.
    var actions: EditorActions? {
        get { bridge.actions }
        set { bridge.actions = newValue }
    }

    /// The web view for `endpoint`, created and loaded on first use.
    func webView(for endpoint: IDEEndpoint, projectID: UUID) -> WKWebView {
        if let entry, entry.endpointURL == endpoint.url { return entry.view }
        let configuration = WKWebViewConfiguration()
        // Only the mobile content mode honors the viewport the touch adaptations scale with.
        configuration.defaultWebpagePreferences.preferredContentMode = touchOptimized ? .mobile : .desktop
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: projectID)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        installUserScripts(in: configuration.userContentController)
        configuration.userContentController.add(bridge, name: EditorBridgeScript.handlerName)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isInspectable = false
        // Keeps VS Code's own gestures; the system's back swipe would leave the editor page.
        view.allowsBackForwardNavigationGestures = false
        configureScrolling(of: view)
        view.load(URLRequest(url: endpoint.url))
        entry = (endpoint.url, view)
        applyTouchOptimization()
        return view
    }

    /// Switches the touch adaptations of the current editor. The content mode changes with it,
    /// which takes a reload; VS Code restores its state from the project's data store.
    func setTouchOptimized(_ enabled: Bool) {
        guard enabled != touchOptimized else { return }
        touchOptimized = enabled
        guard let view = entry?.view else { return }
        view.configuration.defaultWebpagePreferences.preferredContentMode = enabled ? .mobile : .desktop
        installUserScripts(in: view.configuration.userContentController)
        configureScrolling(of: view)
        view.reload()
    }

    /// VS Code's touch defaults only apply when it starts, so they come with the next load.
    private func installUserScripts(in controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(EditorBridgeScript.userScript)
        controller.addUserScript(EditorTouchScript.userScript)
        if touchOptimized { controller.addUserScript(EditorTouchScript.defaultsScript) }
    }

    /// In the mobile content mode the page fills the whole view and stays in place: VS Code
    /// scrolls its parts itself, and the web view would otherwise shift the page for the keyboard
    /// or let it bounce.
    private func configureScrolling(of view: WKWebView) {
        let scrollView = view.scrollView
        scrollView.contentInsetAdjustmentBehavior = touchOptimized ? .never : .automatic
        scrollView.isScrollEnabled = !touchOptimized
        scrollView.bounces = !touchOptimized
        scrollView.showsVerticalScrollIndicator = !touchOptimized
        scrollView.showsHorizontalScrollIndicator = !touchOptimized
    }

    /// The editor's size changed, for example after rotating or when the keyboard appeared.
    func editorDidResize(width: Double) {
        guard width > 0, width != self.width else { return }
        self.width = width
        if touchOptimized { applyTouchOptimization() }
    }

    /// Also called after each page load, which starts without the touch adaptations.
    func applyTouchOptimization() {
        guard let view = entry?.view else { return }
        view.evaluateJavaScript(EditorTouchScript.apply(touchOptimized, width: width > 0 ? width : view.bounds.width))
    }

    /// Sends a key or shortcut from the keyboard bar to the focused element in VS Code.
    func send(_ key: EditorKey) {
        entry?.view.evaluateJavaScript(EditorTouchScript.send(key))
    }

    /// Releases the view once its session has ended.
    func discardUnlessCurrent(_ endpoint: IDEEndpoint?) {
        guard entry?.endpointURL != endpoint?.url else { return }
        entry?.view.removeFromSuperview()
        entry = nil
    }

    /// Receives `runfern` messages from the editor page. A separate object, because the content
    /// controller keeps its handlers alive for as long as the web view exists.
    private final class BridgeHandler: NSObject, WKScriptMessageHandler {
        var actions: EditorActions?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.body as? String {
            case EditorTouchScript.readyMessage:
                IDEWebViewCache.shared.applyTouchOptimization()
                return
            case EditorTouchScript.hapticMessage:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                return
            default:
                break
            }
            guard let action = message.body as? String, let url = URL(string: "runfern://\(action)") else { return }
            DiagnosticsLog.record(.info, .app, "Editor action: \(action)")
            actions?.perform(url)
        }
    }

    /// Deletes the editor state of a removed project (PRJ06).
    func removeData(for projectID: UUID) async {
        // WebKit's static data store functions crash when no web view was created in this process
        // yet (its main run loop isn't set up), for example when no editor was opened since launch.
        if entry == nil { _ = WKWebView(frame: .zero) }
        guard await WKWebsiteDataStore.allDataStoreIdentifiers.contains(projectID) else { return }
        try? await WKWebsiteDataStore.remove(forIdentifier: projectID)
    }
}
