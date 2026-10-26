import SwiftUI

/// Tools and VS Code extensions of an existing environment. Applying installs what was added,
/// removes what was deselected, and checks the environment again.
struct InstalledSoftwareView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(Provisioner.self) private var provisioner
    @Environment(RuntimeCoordinator.self) private var runtime
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let environment: DevEnvironment

    @State private var selection = SoftwareSelection(toolchainIds: [])

    private var isLocked: Bool { runtime.activeProjectID == project.id || provisioner.isRunning(project) }

    var body: some View {
        Form {
            if isLocked {
                Section {
                    Label("Stop the environment to change its software.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            SoftwareSections(base: Catalog.baseImage(id: environment.baseImageId), selection: $selection,
                             softwareLocked: isLocked)
        }
        .navigationTitle("Installed Software")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply", role: .confirm) {
                    let needsSetup = !selection.installsSameSoftware(as: environment.software)
                    store.setSoftware(selection, for: project)
                    if needsSetup { provisioner.start(project) }
                    dismiss()
                }
                .disabled(selection == environment.software)
            }
        }
        .onAppear { selection = environment.software }
    }
}
