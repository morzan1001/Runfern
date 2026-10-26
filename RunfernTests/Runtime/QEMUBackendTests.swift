import Foundation
import Testing
@testable import Runfern

/// Command line and selection of the interpreter and JIT backends.
@Suite struct QEMUBackendTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "backend-\(UUID().uuidString)")

    private func accel(_ backend: QEMUBackend) -> String? {
        let configuration = MachineConfiguration(environmentID: UUID(), image: root, overlay: root.appending(path: "o.qcow2"),
                                                 workspace: .workingCopy(root.appending(path: "files")))
        let arguments = QEMUCommandLine.arguments(configuration: configuration, bundle: ImageBundle(directory: root),
                                                  kernelCommandLine: "quiet", sockets: QEMUSockets(directory: root),
                                                  hostIDEPort: 9000, consoleLog: root.appending(path: "console.log"),
                                                  backend: backend)
        return arguments.firstIndex(of: "-accel").map { arguments[$0 + 1] }
    }

    @Test func interpreterUsesALargeCacheWithoutSplitMapping() {
        #expect(accel(.interpreter) == "tcg,thread=multi,tb-size=512")
    }

    @Test func jitWritesAndRunsCodeThroughSeparateMappings() throws {
        let options = try #require(accel(.jit))
        #expect(options.hasPrefix("tcg,thread=multi,tb-size="))
        #expect(options.hasSuffix(",split-wx=on"))
    }

    @Test func backendsLoadDifferentFrameworks() {
        #expect(QEMUBackend.interpreter.frameworkName != QEMUBackend.jit.frameworkName)
        #expect(QEMUBackend.jit.frameworkName.hasSuffix("-jit"))
    }

    @Test func jitNeedsTheSettingTurnedOn() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: JITSupport.enabledKey)
        defer { defaults.set(previous, forKey: JITSupport.enabledKey) }
        defaults.set(false, forKey: JITSupport.enabledKey)
        #expect(!JITSupport.canUse)
        #expect(QEMUBackend.preferred == .interpreter)
    }
}

/// Where project files come from and how the selected software is summarized.
@Suite struct WorkspaceModeTests {
    @Test func folderOnTheDeviceIsMountedDirectly() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mode-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binding = try WorkspaceAccess.makeBinding(for: folder)
        #expect(binding.storageMode == .mountedFolder)
        #expect(binding.isInFiles)
        #expect(try WorkspaceFiles(binding).url.standardizedFileURL.path == folder.standardizedFileURL.path)
    }

    @Test func appInternalProjectsUseTheirWorkingCopy() throws {
        let binding = WorkspaceBinding.appInternal()
        #expect(!binding.isInFiles)
        #expect(try WorkspaceFiles(binding).url == AppPaths.workingCopy(binding.id))
    }

    @Test func softwareSummaryNamesToolsAndCountsExtensions() {
        #expect(SoftwareSelection(toolchainIds: []).summary == String(localized: "None"))
        let python = SoftwareSelection(toolchainIds: ["python-3"])
        #expect(python.summary.contains("Python"))
    }
}
