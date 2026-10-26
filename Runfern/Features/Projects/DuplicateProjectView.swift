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
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Toggle("Include Installed Packages", isOn: $includeSystemState)
                } footer: {
                    Text("The copy is stored only in Runfern and is independent of the original.")
                }
                if runtime.activeProjectID == project.id, includeSystemState {
                    Section {
                        Label("Stop the environment first to copy a consistent system state.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Duplicate Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Duplicate", action: duplicate)
                        .disabled(runtime.activeProjectID == project.id && includeSystemState)
                }
            }
            .onAppear { name = String(localized: "\(project.name) Copy") }
        }
    }

    private func duplicate() {
        do {
            let copy = try store.duplicate(project, name: name, includeSystemState: includeSystemState)
            if store.environment(for: copy)?.isFullyProvisioned == false { provisioner.start(copy) }
            onDuplicated(copy)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
