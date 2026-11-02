import SwiftUI

/// Languages and VS Code extensions of an existing environment, edited in a sheet like Edit Project.
/// Applying installs what was added, removes what was deselected, and checks the environment again.
/// Languages and extensions are chosen on pages pushed inside the sheet's own stack.
struct InstalledSoftwareView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(Provisioner.self) private var provisioner
    @Environment(RuntimeCoordinator.self) private var runtime
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let environment: DevEnvironment

    @State private var selection: SoftwareSelection

    /// Filled here, not in `onAppear`: that runs again whenever a pushed page is popped, and would
    /// reset the edits.
    init(project: Project, environment: DevEnvironment) {
        self.project = project
        self.environment = environment
        _selection = State(initialValue: environment.software)
    }

    private var isLocked: Bool { runtime.activeProjectID == project.id || provisioner.isRunning(project) }

    /// Edits the person would lose by dismissing the sheet (A2).
    private var hasChanges: Bool { selection != environment.software }

    var body: some View {
        NavigationStack {
            Form {
                if isLocked {
                    Section {
                        Group {
                            if provisioner.isRunning(project) {
                                Label("Software can be changed once the setup has finished.", systemImage: "hourglass")
                            } else {
                                Label("Stop the environment to change its software.", systemImage: "info.circle")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                SoftwareSections(base: Catalog.baseImage(id: environment.baseImageId), selection: $selection,
                                 softwareLocked: isLocked)
            }
            .navigationTitle("Installed Software")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { CancelButton(hasChanges: hasChanges) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", role: .confirm) {
                        let needsSetup = !selection.installsSameSoftware(as: environment.software)
                        store.setSoftware(selection, for: project)
                        if needsSetup { provisioner.start(project) }
                        dismiss()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!hasChanges)
                }
            }
            .interactiveDismissDisabled(hasChanges)
        }
    }
}
