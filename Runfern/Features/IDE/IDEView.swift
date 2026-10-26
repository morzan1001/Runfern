import SwiftUI

/// Shell around the IDE. With a real runtime it shows VS Code full screen via the local endpoint;
/// while the runtime is simulated, the built-in editor is used to verify the file pipeline.
/// Runfern's own actions live in the menu bar and in VS Code's status bar (see `EditorActions`).
struct IDEView: View {
    @Environment(RuntimeCoordinator.self) private var runtime
    @Environment(ProjectStore.self) private var store
    @State private var showingPreview = false
    let project: Project
    let close: () -> Void

    var body: some View {
        if runtime.activeProjectID != project.id || runtime.endpoint == nil {
            NavigationStack {
                ContentUnavailableView("Environment Not Active", systemImage: "pause.circle")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Overview", systemImage: "square.grid.2x2", action: close)
                        }
                    }
            }
        } else if runtime.isSimulated, let binding = store.binding(for: project) {
            WorkspaceEditorView(project: project, binding: binding, close: close)
        } else if let endpoint = runtime.endpoint {
            editor(endpoint)
        }
    }

    /// The editor uses the whole window without any controls of Runfern on top.
    private func editor(_ endpoint: IDEEndpoint) -> some View {
        EditorSurface(endpoint: endpoint, projectID: project.id,
                      touchOptimized: store.environment(for: project)?.touchOptimized == true,
                      actions: actions) { runtime.connectionLost() }
            .focusedSceneValue(\.editorActions, actions)
            .overlay {
                if runtime.session?.isConnected == false {
                    ContentUnavailableView {
                        Label("Connection Lost", systemImage: "bolt.horizontal.circle")
                    } description: {
                        Text(runtime.lastError ?? String(localized: "Runfern is trying to restore the connection…"))
                    } actions: {
                        Button("Reconnect") { Task { await runtime.reconnect() } }
                    }
                    .background(.regularMaterial)
                }
            }
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .sheet(isPresented: $showingPreview) { DevServerPreviewView() }
    }

    /// Going back to the overview does not stop the environment, and the editor stays as it is (RUN04).
    private var actions: EditorActions {
        EditorActions(showOverview: close, showPreview: { showingPreview = true })
    }
}
