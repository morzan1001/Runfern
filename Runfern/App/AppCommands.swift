import SwiftUI

/// What the project overview of the focused window can do, for the menu bar.
struct OverviewActions {
    let newProject: () -> Void
    let importProject: () -> Void
    let showSettings: () -> Void
    /// Set while an environment runs and its editor is closed.
    let returnToEditor: (() -> Void)?
}

extension FocusedValues {
    @Entry var overviewActions: OverviewActions?
}

/// File ▸ New Project / Import Project… and Runfern ▸ Settings… in the iPadOS menu bar.
/// The commands are disabled while a sheet or the editor covers the overview, so their keys
/// reach VS Code instead.
struct AppCommands: Commands {
    @FocusedValue(\.overviewActions) private var actions

    var body: some Commands {
        CommandGroup(before: .newItem) {
            Button("New Project") { actions?.newProject() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button("Import Project…") { actions?.importProject() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { actions?.showSettings() }
                .keyboardShortcut(",")
                .disabled(actions == nil)
        }
    }
}
