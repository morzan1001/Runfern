import SwiftUI

/// Archive or restore, the same in swipe actions, context menus, and the detail's More menu.
struct ArchiveButton: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        if project.isArchived {
            Button("Restore", systemImage: "tray.and.arrow.up") { store.setArchived(false, for: project) }
        } else {
            Button(String(localized: "action.archive", defaultValue: "Archive"), systemImage: "archivebox") {
                store.setArchived(true, for: project)
            }
        }
    }
}
