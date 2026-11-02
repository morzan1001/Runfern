#if RUNFERN_JIT
import CryptoKit
import Foundation
import Synchronization

/// The iPad's Remote Pairing record for its developer services, which the built-in JIT needs.
///
/// StikJIT reaches the developer services through Remote Pairing (the protocol Xcode uses since
/// iOS 17), so it reads an RPPairing file: a property list with the host's Ed25519 key pair
/// (`public_key`, `private_key`), its `identifier`, and optionally `alt_irk`. That is not the
/// lockdown pairing record that Finder or libimobiledevice keep (`HostID`, `HostCertificate`, …);
/// the iPad never accepts such a record for Remote Pairing.
///
/// The file is created once: on this iPad (`OnDevicePairing`, iPadOS 27), or on a computer with
/// `Tools/JIT/create-pairing-file.sh`, idevice_pair, or iloader, and then imported. Runfern keeps
/// only the four keys StikJIT reads, in its own container, protected and excluded from backups, and
/// never logs or exports it.
nonisolated enum PairingFile {
    enum ImportError: LocalizedError, Equatable {
        case invalid
        case lockdownRecord
        case pymobiledevice3Record
        case mismatchedKeys

        var errorDescription: String? {
            switch self {
            case .invalid:
                String(localized: "The file is not a pairing file.")
            case .lockdownRecord:
                String(localized: "This is a lockdown pairing record, as Finder or libimobiledevice create it. The built-in JIT needs a Remote Pairing file instead: create one on this iPad, or on a computer as described in How Runfern Works.")
            case .pymobiledevice3Record:
                String(localized: "This Remote Pairing record comes from pymobiledevice3, which the built-in JIT cannot use. Create a pairing file on this iPad, or on a computer as described in How Runfern Works.")
            case .mismatchedKeys:
                String(localized: "The keys in this pairing file do not belong together. Create a new pairing file.")
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

    /// Read from the file once and kept until Runfern stores or removes the file, so views can ask
    /// for it as often as they draw.
    static var state: State {
        knownState.withLock { known in
            if let known { return known }
            let state = readState()
            known = state
            return state
        }
    }

    private static let knownState = Mutex<State?>(nil)

    private static func readState() -> State {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        do {
            try validate(data)
            return .ready
        } catch {
            return .unusable
        }
    }

    /// The pairing record, if a usable one was imported, reduced to the keys StikJIT reads.
    static func load() throws -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try normalized(data)
    }

    /// Copies the file at `source` (from the document picker) into Runfern, replacing an earlier one.
    static func importFile(at source: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try store(read(source))
    }

    /// Checks `data`, reduces it to the keys StikJIT reads, and stores it, replacing an earlier file.
    static func store(_ data: Data) throws {
        let reduced = try normalized(data)
        var destination = url
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { knownState.withLock { $0 = nil } }
        try reduced.write(to: destination, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
    }

    /// Checks `data` the way StikJIT's reader (idevice `RpPairingFile::from_bytes`) does: an XML or
    /// binary property list with a 32-byte `public_key`, a 32-byte `private_key`, and an
    /// `identifier` string (`host_identifier` in pymobiledevice3's records). `alt_irk` is optional. Also checks that the public key belongs to the
    /// private key (both are Ed25519 in their 32-byte RFC 8032 form), because the iPad would
    /// otherwise reject the file only when JIT is first needed.
    static func validate(_ data: Data) throws {
        _ = try normalized(data)
    }

    /// `data` as an XML property list with only the keys StikJIT reads. Some tools, iloader among
    /// them, add lockdown secrets to the same file; those never reach the helper.
    static func normalized(_ data: Data) throws -> Data {
        guard let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportError.invalid
        }
        guard let publicKey = record["public_key"] as? Data, publicKey.count == 32,
              let privateKey = record["private_key"] as? Data, privateKey.count == 32 else {
            let lockdownKeys = ["HostID", "HostCertificate", "HostPrivateKey", "SystemBUID", "DeviceCertificate"]
            let isLockdownRecord = lockdownKeys.contains { record[$0] != nil }
            throw isLockdownRecord ? ImportError.lockdownRecord : ImportError.invalid
        }
        // pymobiledevice3 names the identifier `host_identifier` in records of pairings the iPad
        // started, and keeps none for pairings it started itself.
        var foundIdentifier: String?
        for key in ["identifier", "host_identifier"] {
            if let value = record[key] as? String, !value.isEmpty {
                foundIdentifier = value
                break
            }
        }
        guard let identifier = foundIdentifier else {
            let isPymobiledevice3Record = record["remote_unlock_host_key"] != nil || record["peer_alt_irk"] != nil
            throw isPymobiledevice3Record ? ImportError.pymobiledevice3Record : ImportError.invalid
        }
        guard let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
              signingKey.publicKey.rawRepresentation == publicKey else {
            throw ImportError.mismatchedKeys
        }
        var kept: [String: Any] = ["public_key": publicKey, "private_key": privateKey, "identifier": identifier]
        // The iPad's IRK, which idevice and pymobiledevice3 name differently.
        for key in ["alt_irk", "peer_alt_irk"] {
            if let altIRK = record[key] as? Data, altIRK.count == 16 {
                kept["alt_irk"] = altIRK
                break
            }
        }
        guard let reduced = try? PropertyListSerialization.data(fromPropertyList: kept, format: .xml, options: 0) else {
            throw ImportError.invalid
        }
        return reduced
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
        knownState.withLock { $0 = nil }
    }
}
#endif
