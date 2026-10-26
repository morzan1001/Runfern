#if DEBUG
import SwiftUI

/// Services with sample projects in every relevant state, for previews of project screens.
@MainActor
struct ProjectPreviewFixture {
    enum Sample {
        case setupFailed, ready, startFailed
    }

    let store = ProjectStore(fileURL: URL.temporaryDirectory.appending(path: "preview-\(UUID().uuidString).json"))
    let sync = SyncCenter()
    let images = ImageLibrary()
    let connectivity = Connectivity()
    let provisioner: Provisioner
    let runtime: RuntimeCoordinator

    init() {
        provisioner = Provisioner(store: store, images: images, sync: sync, connectivity: connectivity)
        runtime = RuntimeCoordinator(store: store, sync: sync)
    }

    func project(_ sample: Sample) -> Project {
        let image = Catalog.baseImages[0]
        let python = Catalog.toolchain(id: "python-3").map { [$0] } ?? []
        let project = try! store.createProject(name: "Weather Station", details: "Reads sensors and plots the data",
                                               source: .pythonStarter, baseImage: image, toolchains: python,
                                               binding: .appInternal())
        switch sample {
        case .setupFailed:
            store.markCompleted(.checkStorage, for: project.environmentId)
            store.setState(.failed, error: String(localized: "Debian 12 has not been published for download yet."),
                           for: project.environmentId)
        case .ready, .startFailed:
            for step in ProvisioningStep.allCases { store.markCompleted(step, for: project.environmentId) }
            store.setState(sample == .ready ? .ready : .failed,
                           error: sample == .ready ? nil : String(localized: "Linux could not start. Reset the environment to set it up again."),
                           for: project.environmentId)
        }
        return project
    }

    func environment<Content: View>(_ content: Content) -> some View {
        content
            .environment(store)
            .environment(sync)
            .environment(images)
            .environment(connectivity)
            .environment(provisioner)
            .environment(runtime)
    }
}

#Preview("Setup failed") {
    let fixture = ProjectPreviewFixture()
    return fixture.environment(NavigationStack { ProjectDetailView(project: fixture.project(.setupFailed)) {} })
}

#Preview("Ready") {
    let fixture = ProjectPreviewFixture()
    return fixture.environment(NavigationStack { ProjectDetailView(project: fixture.project(.ready)) {} })
}

#Preview("Installed software") {
    let fixture = ProjectPreviewFixture()
    let project = fixture.project(.ready)
    return fixture.environment(NavigationStack {
        InstalledSoftwareView(project: project, environment: fixture.store.environment(for: project)!)
    })
}

#Preview("Start failed") {
    let fixture = ProjectPreviewFixture()
    return fixture.environment(NavigationStack { ProjectDetailView(project: fixture.project(.startFailed)) {} })
}

#Preview("New project") {
    let fixture = ProjectPreviewFixture()
    fixture.store.savePreset(.previewSample)
    return fixture.environment(NewProjectView { _ in })
}

#Preview("Preset") {
    ProjectPreviewFixture().environment(PresetEditorView(preset: .previewSample))
}

#Preview("Setup running") {
    let fixture = ProjectPreviewFixture()
    let project = fixture.project(.setupFailed)
    return Form {
        SetupSteps(environment: fixture.store.environment(for: project)!, currentStep: .fetchBase,
                   progress: 0.3, isRunning: true)
    }
}

private extension EnvironmentPreset {
    static let previewSample = EnvironmentPreset(id: UUID(), name: "Python", baseImageId: Catalog.baseImages[0].id,
                                                 toolchainIds: ["python-3"], extensionIds: [], resources: .standard)
}
#endif
