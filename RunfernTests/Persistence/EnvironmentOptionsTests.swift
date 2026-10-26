import Foundation
import Testing
@testable import Runfern

/// Verifies adding tools later (IMG07) and resource profiles (RUN07).
@MainActor
@Suite struct EnvironmentOptionsTests {
    private func makeProject() throws -> (ProjectStore, Project) {
        let store = ProjectStore(fileURL: URL.temporaryDirectory.appending(path: "store-\(UUID().uuidString).json"))
        let image = try #require(Catalog.baseImage(id: "debian-12-arm64"))
        let project = try store.createProject(name: "Tools", details: "", source: .empty, baseImage: image,
                                              toolchains: [try #require(Catalog.toolchain(id: "python-3"))],
                                              binding: .appInternal())
        for step in ProvisioningStep.allCases { store.markCompleted(step, for: project.environmentId) }
        store.setState(.ready, for: project.environmentId)
        return (store, project)
    }

    @Test func addingToolsOnlyRepeatsInstallAndHealthCheck() throws {
        let (store, project) = try makeProject()

        var software = try #require(store.environment(for: project)?.software)
        software.setTool("nodejs-22", selected: true)
        store.setSoftware(software, for: project)

        let env = try #require(store.environment(for: project))
        #expect(env.toolchainIds == ["python-3", "nodejs-22"])
        #expect(env.hasCompleted(.prepareWorkspace))
        #expect(env.hasCompleted(.createSystemDisk))
        #expect(!env.hasCompleted(.installToolchains))
        #expect(!env.hasCompleted(.verify))
        #expect(env.state == .provisioning)
    }

    @Test func resourceProfilesRespectDeviceMemory() {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024

        #expect(ResourceProfile.light.isSupported(physicalMemory: eightGB, processorCount: 8))
        #expect(ResourceProfile.standard.isSupported(physicalMemory: eightGB, processorCount: 8))
        #expect(!ResourceProfile.performance.isSupported(physicalMemory: eightGB, processorCount: 8))
        #expect(!ResourceProfile.standard.isSupported(physicalMemory: eightGB, processorCount: 2))
    }

    @Test func environmentsWithoutProfileUseStandard() throws {
        let json = #"{"id":"\#(UUID().uuidString)","baseImageId":"debian-12-arm64","baseCatalogVersion":1,"toolchainIds":[],"state":"ready","completedSteps":[]}"#
        let env = try JSONDecoder().decode(DevEnvironment.self, from: Data(json.utf8))

        #expect(env.resources == nil)
        #expect(env.effectiveResources == .standard)
    }

    @Test func bundledCatalogOffersAllProfilesForEveryBase() {
        for image in Catalog.baseImages {
            #expect(Set(Catalog.toolchains(for: image).map(\.id)) == ["python-3", "nodejs-22", "java-21"])
        }
    }
}
