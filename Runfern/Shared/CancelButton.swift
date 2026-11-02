import SwiftUI

/// Cancel for a sheet's `.cancellationAction` (A1/A2). Esc triggers it; with unsaved input it asks
/// first. Pair with `.interactiveDismissDisabled(hasChanges)`.
struct CancelButton: View {
    var hasChanges = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false

    var body: some View {
        Button("Cancel", role: .cancel) {
            if hasChanges { confirmingDiscard = true } else { dismiss() }
        }
        .keyboardShortcut(.cancelAction)
        // On the button, so on iPad the dialog points at it.
        .confirmationDialog("Discard Changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
    }
}
