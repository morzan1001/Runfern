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
        software.setTool("nodejs-24", selected: true)
        store.setSoftware(software, for: project)

        let env = try #require(store.environment(for: project))
        #expect(env.toolchainIds == ["python-3", "nodejs-24"])
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

    /// Every base offers the portable toolchains; Swift only where swift.org has a matching build.
    @Test func bundledCatalogOffersTheToolchainsOfEveryBase() {
        let portable: Set = ["python-3", "nodejs-24", "nodejs-26", "java-21", "java-25", "java-27", "go", "rust",
                             "dotnet", "bun", "deno", "zig"]
        for image in Catalog.baseImages {
            let offered = Set(Catalog.toolchains(for: image).map(\.id))
            #expect(offered.isSuperset(of: portable), "\(image.id)")
            #expect(offered.subtracting(portable).allSatisfy { $0.hasPrefix("swift-") }, "\(image.id)")
            #expect(offered.filter { $0.hasPrefix("swift-") }.count <= 1, "\(image.id)")
        }
    }

    @Test func familiesGroupVersionsAndDistributionsGroupReleases() throws {
        let debian = try #require(Catalog.baseImage(id: "debian-13-arm64"))
        let families = Catalog.toolchainFamilies(for: debian)
        #expect(families.first { $0.id == "nodejs" }?.versions.map(\.version) == ["24", "26"])
        #expect(families.first { $0.id == "java" }?.versions.map(\.version) == ["21", "25", "27"])
        #expect(Set(families.map(\.id)).count == families.count)
        #expect(Catalog.baseImageFamilies.first { $0.distribution == "Ubuntu" }?.releases.map(\.release) == ["24.04", "26.04"])
    }
}
