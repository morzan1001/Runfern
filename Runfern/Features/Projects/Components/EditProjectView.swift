import SwiftUI

/// Name and description of a project (PRJ04), edited in a sheet instead of inline fields.
struct EditProjectView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var name: String
    @State private var details: String

    /// Filled here, not in `onAppear`, so `hasChanges` is right from the first frame.
    init(project: Project) {
        self.project = project
        _name = State(initialValue: project.name)
        _details = State(initialValue: project.details)
    }

    /// Edits the person would lose by dismissing the sheet (A2).
    private var hasChanges: Bool { name != project.name || details != project.details }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description (Optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Edit Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { CancelButton(hasChanges: hasChanges) }
                ToolbarItem(placement: .confirmationAction) {
                    // ⌘↩, not ↩: Description is a multi-line field.
                    Button("Save", role: .confirm) {
                        store.rename(project, name: name, details: details)
                        dismiss()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasChanges)
                }
            }
            .interactiveDismissDisabled(hasChanges)
        }
    }
}
