import SwiftUI

/// Actions of the editor that is currently in focus. The full-screen editor shows no controls of its
/// own; these actions are reached through the menu bar, keyboard shortcuts, and the Runfern
/// extension inside VS Code (`runfern://` links).
struct EditorActions {
    let showOverview: () -> Void
    let showPreview: () -> Void

    /// Handles a link opened by the Runfern VS Code extension. Returns `false` for unknown actions.
    @discardableResult
    func perform(_ url: URL) -> Bool {
        guard url.scheme == "runfern" else { return false }
        switch url.host() {
        case "overview": showOverview()
        case "preview": showPreview()
        default: return false
        }
        return true
    }
}

extension FocusedValues {
    @Entry var editorActions: EditorActions?
}

/// The "Project" menu in the iPadOS menu bar.
struct EditorCommands: Commands {
    @FocusedValue(\.editorActions) private var actions

    var body: some Commands {
        CommandMenu("Project") {
            Button("Back to Overview", systemImage: "square.grid.2x2") { actions?.showOverview() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Development Server Preview", systemImage: "safari") { actions?.showPreview() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(actions == nil)
        }
    }
}
