#if RUNFERN_JIT
import Foundation

/// The iPad's Remote Pairing record for its developer services, which the built-in JIT needs.
///
/// StikJIT reaches the developer services through Remote Pairing (the protocol Xcode uses since
/// iOS 17), so it reads an RPPairing file: a property list with the host's Ed25519 key pair
/// (`public_key`, `private_key`), its `identifier`, and optionally `alt_irk`. That is not the
/// lockdown pairing record that Finder or `idevicepair` keep (`HostID`, `HostCertificate`, …); the
/// iPad never accepts such a record for Remote Pairing. The file is created once, for example by
/// iloader or idevice's `remotepairing_lockdown pair` on a computer; Runfern keeps the imported
/// copy in its own container, protected and excluded from backups, and never logs or exports it.
nonisolated enum PairingFile {
    enum ImportError: LocalizedError, Equatable {
        case invalid
        case lockdownRecord

        var errorDescription: String? {
            switch self {
            case .invalid:
                String(localized: "The file is not a pairing file.")
            case .lockdownRecord:
                String(localized: "This is a lockdown pairing record, as Finder or idevicepair create it. The built-in JIT needs a Remote Pairing file instead; see How Runfern Works for how to create one.")
            }
        }
    }

    /// What is stored in Runfern right now.
    enum State: Equatable {
        case missing
        /// An RPPairing file, as StikJIT needs it.
        case ready
        /// A file that StikJIT cannot use, for example a lockdown record imported by an earlier
        /// version of Runfern; it has to be replaced.
        case unusable
    }

    static var url: URL { AppPaths.pairingFile }

    static var state: State {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        do {
            try validate(data)
            return .ready
        } catch {
            return .unusable
        }
    }

    /// The pairing record, if a usable one was imported.
    static func load() throws(ImportError) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try validate(data)
        return data
    }

    /// Copies the file at `source` (from the document picker) into Runfern, replacing an earlier one.
    static func importFile(at source: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let data = try read(source)
        try validate(data)
        var destination = url
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
    }

    /// Checks `data` the way StikJIT's reader (idevice `RpPairingFile::from_bytes`) does: an XML or
    /// binary property list with a 32-byte `public_key`, a 32-byte `private_key`, and an
    /// `identifier` string. `alt_irk` is optional.
    static func validate(_ data: Data) throws(ImportError) {
        guard let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw .invalid
        }
        if let publicKey = record["public_key"] as? Data, publicKey.count == 32,
           let privateKey = record["private_key"] as? Data, privateKey.count == 32,
           let identifier = record["identifier"] as? String, !identifier.isEmpty {
            return
        }
        let lockdownKeys = ["HostID", "HostCertificate", "HostPrivateKey", "SystemBUID", "DeviceCertificate"]
        throw lockdownKeys.contains { record[$0] != nil } ? .lockdownRecord : .invalid
    }

    /// Pairing records are small property lists, so at most `maximumSize` bytes are read. The read
    /// is coordinated, which also downloads a file that is still in iCloud Drive (for example one
    /// sent with AirDrop to iCloud Downloads).
    private static func read(_ source: URL) throws -> Data {
        let maximumSize = 256 * 1024
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(ImportError.invalid)
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordinationError) { url in
            result = Result {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
                guard !data.isEmpty, data.count <= maximumSize else { throw ImportError.invalid }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
