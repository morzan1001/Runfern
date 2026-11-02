import SwiftUI

/// A separate window for one project (UX05). Closing it never stops the environment.
struct ProjectWindow: View {
    static let id = "project"

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    let projectID: UUID?

    @State private var showingIDE = false

    private var project: Project? { projectID.flatMap { store.project(id: $0) } }

    var body: some View {
        NavigationStack {
            if let project {
                ProjectDetailView(project: project) { showingIDE = true }
                    .fullScreenCover(isPresented: $showingIDE) {
                        IDEView(project: project) { showingIDE = false }
                    }
            } else {
                ContentUnavailableView {
                    Label("Project Not Found", systemImage: "questionmark.folder")
                } description: {
                    Text("The project was removed or is not available.")
                } actions: {
                    Button("Close Window") { dismissWindow() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        // Removed while this window is open (for example from the overview): the window closes itself.
        // Only the transition counts, so a restored window whose project is already gone keeps the button.
        .onChange(of: project == nil) { _, gone in
            if gone { dismissWindow() }
        }
    }
}
