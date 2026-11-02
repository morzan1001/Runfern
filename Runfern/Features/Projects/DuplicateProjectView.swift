import SwiftUI

/// Creates an independent copy of a project (PRJ07).
struct DuplicateProjectView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(Provisioner.self) private var provisioner
    @Environment(RuntimeCoordinator.self) private var runtime
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let onDuplicated: (Project) -> Void

    @State private var name = ""
    @State private var includeSystemState = true
    @State private var isDuplicating = false
    @State private var errorMessage: String?

    /// A name is needed, and a running environment's system state can't be copied consistently.
    private var canDuplicate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(runtime.activeProjectID == project.id && includeSystemState)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                        .onSubmit {
                            if canDuplicate { Task { await duplicate() } }
                        }
                    Toggle("Include Installed Packages", isOn: $includeSystemState)
                } footer: {
                    Text("The copy is stored only in Runfern and is independent of the original.")
                }
                if runtime.activeProjectID == project.id, includeSystemState {
                    Section {
                        StatusLabel("Stop the environment first to copy a consistent system state.")
                    }
                }
            }
            .disabled(isDuplicating)
            .navigationTitle("Duplicate Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // The copy keeps running once started, so there is nothing to cancel meanwhile (A3).
                    CancelButton().disabled(isDuplicating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isDuplicating {
                        ProgressView()
                    } else {
                        Button("Duplicate", role: .confirm) { Task { await duplicate() } }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!canDuplicate)
                    }
                }
            }
            .interactiveDismissDisabled(isDuplicating)
            .errorAlert("Couldn’t Duplicate Project", message: $errorMessage)
            .onAppear { name = String(localized: "\(project.name) Copy") }
        }
    }

    private func duplicate() async {
        guard !isDuplicating else { return }
        isDuplicating = true
        defer { isDuplicating = false }
        do {
            let copy = try await store.duplicate(project, name: name, includeSystemState: includeSystemState)
            if store.environment(for: copy)?.isFullyProvisioned == false { provisioner.start(copy) }
            onDuplicated(copy)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
