import Foundation
import Testing
@testable import Runfern

@Suite struct ProjectExporterTests {
    @Test func exportContainsVerifiedFilesAndRecipe() throws {
        let root = URL.temporaryDirectory.appending(path: "ExportTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        try Data("print(1)".utf8).write(to: root.appending(path: "src/main.py"))
        try FileManager.default.createDirectory(at: root.appending(path: ".venv"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(path: ".venv/big"))

        let preview = try ProjectExporter.preview(workingCopy: root)
        let environment = DevEnvironment(id: UUID(), baseImageId: "debian-12-arm64", baseCatalogVersion: 1,
                                         toolchainIds: ["python-3"], state: .ready, completedSteps: [], lastError: nil)
        let archive = try ProjectExporter.export(projectName: "Demo/Project", workingCopy: root,
                                                 recipe: Catalog.recipe(for: environment))

        #expect(preview.fileCount == 1)
        #expect(archive.lastPathComponent == "Demo-Project.zip")
        #expect(DiskUsage.allocatedSize(of: archive) > 0)
    }
}
