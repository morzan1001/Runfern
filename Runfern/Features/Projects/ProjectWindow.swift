import SwiftUI

/// A separate window for one project (UX05). Closing it never stops the environment.
struct ProjectWindow: View {
    static let id = "project"

    @Environment(ProjectStore.self) private var store
    let projectID: UUID?

    @State private var showingIDE = false

    var body: some View {
        NavigationStack {
            if let projectID, let project = store.project(id: projectID) {
                ProjectDetailView(project: project) { showingIDE = true }
                    .fullScreenCover(isPresented: $showingIDE) {
                        IDEView(project: project) { showingIDE = false }
                    }
            } else {
                ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder",
                                       description: Text("The project was removed or is not available."))
            }
        }
    }
}
