import Foundation
import Testing
@testable import Runfern

/// Verifies image bundles, overlays, and the QEMU command line (Plan 4.1, 4.2, ADR05).
@Suite struct ImageBundleTests {
    let root: URL

    init() throws {
        root = URL.temporaryDirectory.appending(path: "ImageBundleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Minimal qcow2 header carrying only magic, version, and virtual size.
    static func qcow2Base(size: UInt64) -> Data {
        var data = Data(count: 512)
        data.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xFB])
        data[7] = 3
        withUnsafeBytes(of: size.bigEndian) { data.replaceSubrange(24..<32, with: $0) }
        return data
    }

    /// Writes a ustar archive with the given files.
    static func tar(_ files: [(String, Data)]) -> Data {
        var archive = Data()
        for (name, content) in files {
            var header = Data(count: 512)
            header.replaceSubrange(0..<name.utf8.count, with: Data(name.utf8))
            func field(_ offset: Int, _ value: String) {
                header.replaceSubrange(offset..<(offset + value.utf8.count), with: Data(value.utf8))
            }
            field(100, "0000644\0")
            field(124, String(format: "%011o\0", content.count))
            field(136, "00000000000\0")
            header[156] = UInt8(ascii: "0")
            field(257, "ustar\0")
            field(263, "00")
            field(148, "        ")
            let checksum = header.reduce(0) { $0 + Int($1) }
            field(148, String(format: "%06o\0 ", checksum))
            archive.append(header)
            archive.append(content)
            archive.append(Data(count: (512 - content.count % 512) % 512))
        }
        archive.append(Data(count: 1024))
        return archive
    }

    private func bundleArchive(protocolVersion: Int = agentProtocolVersion) throws -> URL {
        let manifest = #"{"format":1,"kernelCommandLine":"root=/dev/vda1 ro","agentProtocolVersion":\#(protocolVersion)}"#
        let url = root.appending(path: "image.runfernimage")
        try Self.tar([("image.json", Data(manifest.utf8)),
                      ("disk.qcow2", Self.qcow2Base(size: 16 << 30)),
                      ("vmlinuz", Data("kernel".utf8)),
                      ("initrd.img", Data("initrd".utf8))]).write(to: url)
        return url
    }

    @Test func installsBundleAndReadsManifest() throws {
        let target = root.appending(path: "Images/debian")
        try ImageBundle.install(archive: try bundleArchive(), to: target)
        defer { try? ImageBundle.remove(target) }

        let bundle = ImageBundle(directory: target)
        #expect(try bundle.manifest().kernelCommandLine == "root=/dev/vda1 ro")
        #expect(try String(contentsOf: bundle.kernel, encoding: .utf8) == "kernel")
        #expect(try Qcow2Overlay.virtualSize(of: bundle.disk) == 16 << 30)
    }

    @Test func rejectsIncompatibleAgent() throws {
        let target = root.appending(path: "Images/old")
        #expect(throws: ImageBundle.BundleError.self) {
            try ImageBundle.install(archive: try bundleArchive(protocolVersion: 99), to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
    }

    @Test func rejectsPathTraversal() throws {
        let archive = root.appending(path: "evil.tar")
        try Self.tar([("../escape.txt", Data("x".utf8))]).write(to: archive)
        #expect(throws: TarExtractor.TarError.self) {
            try TarExtractor.extract(archive, to: root.appending(path: "out"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "escape.txt").path(percentEncoded: false)))
    }

    @Test func overlayReferencesBaseRelatively() throws {
        let base = root.appending(path: "Images/debian/disk.qcow2")
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.qcow2Base(size: 8 << 30).write(to: base)
        let overlay = root.appending(path: "Environments/E1/system.qcow2")

        try Qcow2Overlay.create(at: overlay, backingFile: base)

        let data = try Data(contentsOf: overlay)
        #expect(data.count == 4 * 65_536)
        #expect(try Qcow2Overlay.virtualSize(of: overlay) == 8 << 30)
        #expect(data.range(of: Data("../../Images/debian/disk.qcow2".utf8)) != nil)
        #expect(data.range(of: Data("qcow2".utf8)) != nil)
    }

    @Test func overlayRequiresQcow2Base() throws {
        let base = root.appending(path: "not-a-disk")
        try Data("hello".utf8).write(to: base)
        #expect(throws: Qcow2Overlay.OverlayError.self) {
            try Qcow2Overlay.create(at: root.appending(path: "o.qcow2"), backingFile: base)
        }
    }

    @Test func commandLineKeepsGuestPrivate() throws {
        let configuration = MachineConfiguration(environmentID: UUID(), image: root, overlay: root.appending(path: "a,b.qcow2"),
                                                 workspace: .workingCopy(root.appending(path: "files")), memoryMB: 2048, cpuCount: 2)
        let arguments = QEMUCommandLine.arguments(configuration: configuration, bundle: ImageBundle(directory: root),
                                                  kernelCommandLine: "quiet", sockets: QEMUSockets(directory: root),
                                                  hostIDEPort: 41_000, consoleLog: root.appending(path: "console.log"))
        let line = arguments.joined(separator: " ")

        #expect(line.contains("hostfwd=tcp:127.0.0.1:41000-:8080"))
        #expect(!line.contains("0.0.0.0"))
        // The disk is a JSON block node: no option escaping, and powering off parks QEMU.
        #expect(line.contains("a,b.qcow2") && !line.contains("a,,b.qcow2"))
        #expect(arguments.contains("-no-shutdown"))
        #expect(line.contains("name=\(QEMUCommandLine.agentPortName)"))
        #expect(arguments.contains("2048") && arguments.contains("2"))
    }

    @Test func bootFailuresAreRecognizedFromTheConsole() throws {
        let console = root.appending(path: "console.log")
        try Data("Debian GNU/Linux 12 runfern ttyAMA0\nrunfern login:".utf8).write(to: console)
        #expect(BootFailure.detect(in: console) == nil)

        try Data("UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.\n(initramfs)".utf8).write(to: console)
        #expect(BootFailure.detect(in: console) != nil)
        #expect(BootFailure.detect(in: root.appending(path: "missing.log")) == nil)
    }
}
