import SwiftUI

/// Shell around the IDE. With a real runtime it shows VS Code full screen via the local endpoint;
/// while the runtime is simulated, the built-in editor is used to verify the file pipeline.
/// Runfern's own actions live in the menu bar and in VS Code's status bar (see `EditorActions`).
struct IDEView: View {
    @Environment(RuntimeCoordinator.self) private var runtime
    @Environment(ProjectStore.self) private var store
    @State private var showingPreview = false
    /// Identifies this presentation. The editor has a single web view, so only the window that owns it
    /// (`RuntimeCoordinator.editorOwner`) shows VS Code (UX05).
    @State private var token = UUID()
    let project: Project
    let close: () -> Void

    var body: some View {
        // A real container rather than a Group: modifiers on a Group apply to each branch, so switching
        // between the states below would count as disappearing and appearing again.
        ZStack {
            if runtime.activeProjectID != project.id || runtime.endpoint == nil {
                placeholder {
                    Label("Environment Not Active", systemImage: "pause.circle")
                } description: {
                    Text("Start this project’s environment from the overview to keep working in the editor.")
                } actions: {
                    Button("Back to Overview", action: close)
                        .buttonStyle(.borderedProminent)
                }
            } else if runtime.isSimulated, let binding = store.binding(for: project) {
                WorkspaceEditorView(project: project, binding: binding, close: close)
            } else if let endpoint = runtime.endpoint {
                if let owner = runtime.editorOwner, owner != token {
                    placeholder {
                        Label("Shown in Another Window", systemImage: "macwindow.on.rectangle")
                    } description: {
                        Text("VS Code can be shown in one window at a time.")
                    } actions: {
                        Button("Show Here") { runtime.editorOwner = token }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    editor(endpoint)
                }
            }
        }
        // The newest editor takes over; a window that shows no running editor leaves it where it is.
        .onAppear {
            if runtime.activeProjectID == project.id { runtime.editorOwner = token }
        }
        .onDisappear {
            if runtime.editorOwner == token { runtime.editorOwner = nil }
        }
    }

    /// A state without the editor. The title names the project, and the toolbar, the action and the
    /// menu bar's Back to Overview all lead out of the full-screen cover.
    private func placeholder<LabelContent: View, DescriptionContent: View, ActionContent: View>(
        @ViewBuilder label: () -> LabelContent,
        @ViewBuilder description: () -> DescriptionContent,
        @ViewBuilder actions: () -> ActionContent
    ) -> some View {
        NavigationStack {
            ContentUnavailableView(label: label, description: description, actions: actions)
                .navigationTitle(project.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Overview", systemImage: "square.grid.2x2", action: close)
                    }
                }
        }
        .focusedSceneValue(\.editorActions, EditorActions(showOverview: close, showPreview: nil))
    }

    /// The editor uses the whole window without any controls of Runfern on top.
    private func editor(_ endpoint: IDEEndpoint) -> some View {
        let disconnected = runtime.session?.isConnected == false
        return EditorSurface(endpoint: endpoint, projectID: project.id,
                             touchOptimized: store.environment(for: project)?.touchOptimized == true,
                             actions: actions) { runtime.connectionLost() }
            // VoiceOver stays in the overlay while the editor behind it is unusable.
            .accessibilityHidden(disconnected)
            .focusedSceneValue(\.editorActions, actions)
            .overlay {
                if disconnected {
                    connectionLostOverlay
                }
            }
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .sheet(isPresented: $showingPreview) {
                DevServerPreviewView()
                    .presentationSizing(.page)
            }
    }

    /// Covers VS Code, including its own back button, so it offers the way back to the overview too.
    private var connectionLostOverlay: some View {
        ContentUnavailableView {
            Label("Connection Lost", systemImage: "bolt.horizontal.circle")
        } description: {
            Text(connectionMessage)
        } actions: {
            if runtime.isReconnecting {
                ProgressView()
            } else {
                Button("Reconnect") { Task { await runtime.reconnect() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            Button("Back to Overview", action: close)
                .buttonStyle(.bordered)
        }
        .background(.regularMaterial)
    }

    /// The error of the last attempt only while no new attempt runs; both texts are already localized.
    private var connectionMessage: String {
        if !runtime.isReconnecting, let lastError = runtime.lastError { return lastError }
        return String(localized: "Runfern is trying to restore the connection…")
    }

    /// Going back to the overview does not stop the environment, and the editor stays as it is (RUN04).
    private var actions: EditorActions {
        EditorActions(showOverview: close, showPreview: { showingPreview = true })
    }
}
