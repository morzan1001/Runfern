import Foundation
import Testing
@testable import Runfern

/// Verifies VS Code extensions per environment and the person's own presets.
@MainActor
@Suite struct PresetTests {
    private let fileURL = URL.temporaryDirectory.appending(path: "store-\(UUID().uuidString).json")

    private func makeProject(in store: ProjectStore, extensions: [String] = [], settings: String? = nil) throws -> Project {
        let image = try #require(Catalog.baseImage(id: "debian-12-arm64"))
        return try store.createProject(name: "Preset \(UUID().uuidString.prefix(4))", details: "", source: .empty,
                                       baseImage: image, toolchains: [try #require(Catalog.toolchain(id: "python-3"))],
                                       extensions: extensions, resources: .light, editorSettings: settings,
                                       binding: .appInternal())
    }

    @Test func toolsBringTheirExtensions() throws {
        let python = try #require(Catalog.toolchain(id: "python-3"))
        #expect(python.extensions == ["ms-python.python"])
    }

    @Test func changingExtensionsRepeatsOnlyInstallAndHealthCheck() throws {
        let store = ProjectStore(fileURL: fileURL)
        let project = try makeProject(in: store)
        for step in ProvisioningStep.allCases { store.markCompleted(step, for: project.environmentId) }

        var software = try #require(store.environment(for: project)?.software)
        software.setExtension("redhat.vscode-yaml", selected: true)
        store.setSoftware(software, for: project)

        let env = try #require(store.environment(for: project))
        #expect(env.customExtensions == ["redhat.vscode-yaml"])
        #expect(env.hasCompleted(.prepareWorkspace))
        #expect(!env.hasCompleted(.installToolchains))
        #expect(!env.hasCompleted(.verify))
    }

    @Test func presetCapturesProjectAndSurvivesRestart() throws {
        let store = ProjectStore(fileURL: fileURL)
        let project = try makeProject(in: store, extensions: ["redhat.vscode-yaml"], settings: #"{"editor.fontSize": 16}"#)

        let preset = try #require(store.preset(from: project, named: "Python Web"))
        store.savePreset(preset)

        let reloaded = ProjectStore(fileURL: fileURL)
        let saved = try #require(reloaded.presets.first)
        #expect(saved.name == "Python Web")
        #expect(saved.toolchainIds == ["python-3"])
        #expect(saved.extensionIds == ["redhat.vscode-yaml"])
        #expect(saved.resources == .light)
        #expect(saved.editorSettings == #"{"editor.fontSize": 16}"#)

        reloaded.removePreset(saved)
        #expect(reloaded.presets.isEmpty)
    }

    @Test(arguments: ["esbenp.prettier-vscode", "ms-python.python", "a.b"])
    func validExtensionIDs(_ id: String) {
        #expect(EditorExtension.isValidID(id))
    }

    @Test(arguments: ["prettier", "../evil.x", "a.b; rm -rf /", ".hidden", "a b.c"])
    func invalidExtensionIDs(_ id: String) {
        #expect(!EditorExtension.isValidID(id))
    }

    @Test func editorSettingsMustBeAJSONObject() throws {
        try EnvironmentPreset.validateSettings(#"{"editor.fontSize": 16}"#)
        try EnvironmentPreset.validateSettings("")
        #expect(throws: EnvironmentPreset.SettingsError.self) { try EnvironmentPreset.validateSettings("[1, 2]") }
        #expect(throws: EnvironmentPreset.SettingsError.self) { try EnvironmentPreset.validateSettings("{broken") }
    }
}

/// Verifies choosing, deselecting, and removing software (tools and their extensions).
@MainActor
@Suite struct SoftwareSelectionTests {
    @Test func toolsSuggestExtensionsThatCanBeDeselected() {
        var selection = SoftwareSelection(toolchainIds: ["python-3"])
        #expect(selection.extensions == ["ms-python.python"])

        selection.setExtension("ms-python.python", selected: false)
        #expect(selection.extensions.isEmpty)
        #expect(selection.excludedExtensions == ["ms-python.python"])

        selection.setExtension("redhat.vscode-yaml", selected: true)
        selection.setTool("go", selected: true)
        #expect(selection.extensions == ["golang.go", "redhat.vscode-yaml"])

        selection.setTool("python-3", selected: false)
        selection.setExtension("redhat.vscode-yaml", selected: false)
        #expect(selection.toolchainIds == ["go"])
        #expect(selection.extensions == ["golang.go"])
    }

    /// Only one version per language provides `node`, `java`, and so on.
    @Test func choosingAVersionReplacesTheOtherOne() {
        var selection = SoftwareSelection(toolchainIds: ["nodejs-24", "python-3"])
        selection.setTool("nodejs-26", selected: true)
        #expect(selection.toolchainIds == ["python-3", "nodejs-26"])
        selection.setTool("java-21", selected: true)
        selection.setTool("java-27", selected: true)
        #expect(selection.toolchainIds == ["python-3", "nodejs-26", "java-27"])
    }

    @Test func changingSoftwareRepeatsOnlyInstallAndHealthCheck() throws {
        let store = ProjectStore(fileURL: URL.temporaryDirectory.appending(path: "store-\(UUID().uuidString).json"))
        let project = try store.createProject(name: "Software", details: "", source: .empty,
                                              baseImage: try #require(Catalog.baseImage(id: "debian-12-arm64")),
                                              toolchains: [try #require(Catalog.toolchain(id: "python-3"))],
                                              binding: .appInternal())
        for step in ProvisioningStep.allCases { store.markCompleted(step, for: project.environmentId) }
        store.setInstalledSoftware(toolchains: ["python-3"], extensions: ["ms-python.python"], for: project.environmentId)

        store.setSoftware(SoftwareSelection(toolchainIds: ["nodejs-24"], excludedExtensions: ["dbaeumer.vscode-eslint"]),
                          for: project)

        let env = try #require(store.environment(for: project))
        #expect(env.toolchainIds == ["nodejs-24"])
        #expect(env.software.extensions.isEmpty)
        #expect(env.installedToolchainIds == ["python-3"])
        #expect(env.hasCompleted(.createSystemDisk))
        #expect(!env.hasCompleted(.installToolchains))
    }
}
