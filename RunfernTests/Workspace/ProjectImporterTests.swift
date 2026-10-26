import Foundation
import Testing
@testable import Runfern

/// Verifies package import, including the export → import round trip (NEW05, DAT05 V1, T15).
@Suite struct ProjectImporterTests {
    private func makeWorkingCopy() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "ImportSource-\(UUID().uuidString)")
        let files = ["main.py": "print('hi')\n", "src/util.py": "x = 1\n", "Grüße/Ünïcödé.txt": "äöü\n"]
        for (path, content) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        return root
    }

    @MainActor
    @Test func exportedPackageImportsAsNewProject() throws {
        let source = try makeWorkingCopy()
        let environment = DevEnvironment(id: UUID(), baseImageId: Catalog.baseImages[0].id, baseCatalogVersion: 1,
                                         toolchainIds: ["python-3"], state: .ready, completedSteps: [], lastError: nil)
        let archive = try ProjectExporter.export(projectName: "Round Trip", workingCopy: source,
                                                 recipe: Catalog.recipe(for: environment))

        let preview = try ProjectImporter.prepare(archive: archive)
        #expect(preview.projectName == "Round Trip")
        #expect(preview.fileCount == 3)
        #expect(preview.missingComponents.isEmpty)

        let store = ProjectStore(fileURL: URL.temporaryDirectory.appending(path: "store-\(UUID().uuidString).json"))
        let binding = WorkspaceBinding.appInternal()
        let project = try ProjectImporter.commit(preview, store: store, binding: binding)
        defer { store.remove(project) }

        let imported = AppPaths.workingCopy(binding.id)
        #expect(try String(contentsOf: imported.appending(path: "Grüße/Ünïcödé.txt"), encoding: .utf8) == "äöü\n")
        #expect(store.environment(for: project)?.toolchainIds == ["python-3"])
    }

    @Test func pathsEscapingTheDestinationAreRejected() throws {
        for path in ["../evil.txt", "/etc/passwd", "a/../../b", "C:\\x", "./hidden"] {
            #expect(throws: ZipArchiveReader.ZipError.unsafePath(path)) {
                try ZipArchiveReader(data: TestZip.make([(path, Data("x".utf8))]))
            }
        }
    }

    @Test func damagedEntryIsDetected() throws {
        let archive = TestZip.make([("a.txt", Data("hello".utf8))], corruptChecksum: true)
        let reader = try ZipArchiveReader(data: archive)

        #expect(throws: ZipArchiveReader.ZipError.corrupted("a.txt")) {
            try reader.contents(of: reader.entries[0])
        }
    }

    @Test func packageWithWrongChecksumIsRejected() throws {
        let manifest = #"{"format":1,"project":"P","createdAt":"2026-10-25T00:00:00Z","scope":"","excluded":[],"files":{"a.txt":"0000"}}"#
        let url = URL.temporaryDirectory.appending(path: "tampered-\(UUID().uuidString).zip")
        try TestZip.make([("P/manifest.json", Data(manifest.utf8)), ("P/files/a.txt", Data("hello".utf8))]).write(to: url)

        #expect(throws: ProjectImporter.ImportError.self) {
            try ProjectImporter.prepare(archive: url)
        }
    }

    @Test func crc32MatchesReferenceValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

/// Builds small uncompressed ZIP archives for tests.
enum TestZip {
    static func make(_ files: [(path: String, data: Data)], corruptChecksum: Bool = false) -> Data {
        var archive = Data()
        var central = Data()
        for file in files {
            let name = Data(file.path.utf8)
            let crc = CRC32.checksum(file.data) ^ (corruptChecksum ? 1 : 0)
            let size = UInt32(file.data.count)
            let offset = UInt32(archive.count)

            append32(0x0403_4B50, to: &archive)
            [20, 0, 0, 0, 0].forEach { append16($0, to: &archive) }   // version, flags, method, time, date
            [crc, size, size].forEach { append32($0, to: &archive) }
            append16(UInt16(name.count), to: &archive)
            append16(0, to: &archive)                                  // extra length
            archive.append(name)
            archive.append(file.data)

            append32(0x0201_4B50, to: &central)
            [20, 20, 0, 0, 0, 0].forEach { append16($0, to: &central) } // made by, needed, flags, method, time, date
            [crc, size, size].forEach { append32($0, to: &central) }
            append16(UInt16(name.count), to: &central)
            [0, 0, 0, 0].forEach { append16($0, to: &central) }        // extra, comment, disk, internal attributes
            append32(0, to: &central)                                  // external attributes
            append32(offset, to: &central)
            central.append(name)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        append32(0x0605_4B50, to: &archive)
        [0, 0, UInt16(files.count), UInt16(files.count)].forEach { append16($0, to: &archive) }
        append32(UInt32(central.count), to: &archive)
        append32(centralOffset, to: &archive)
        append16(0, to: &archive)
        return archive
    }

    private static func append16(_ value: UInt16, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
