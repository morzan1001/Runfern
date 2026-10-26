import SwiftUI

/// VS Code full screen, with the keyboard bar above the on-screen keyboard while touch
/// optimization is on.
struct EditorSurface: View {
    let endpoint: IDEEndpoint
    let projectID: UUID
    let touchOptimized: Bool
    let actions: EditorActions
    let onConnectionLost: () -> Void

    @State private var keyboard = SoftwareKeyboard()

    var body: some View {
        VStack(spacing: 0) {
            // With touch optimization VS Code ends above the keyboard and its bar, so nothing it
            // shows is covered; otherwise the web view handles the keyboard itself, as in Safari.
            IDEWebView(endpoint: endpoint, projectID: projectID, touchOptimized: touchOptimized, actions: actions,
                       onConnectionLost: onConnectionLost)
                .ignoresSafeArea(touchOptimized ? .container : .all)
            if touchOptimized && keyboard.isVisible {
                EditorKeyboardBar { IDEWebViewCache.shared.send($0) }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: keyboard.isVisible)
    }
}
