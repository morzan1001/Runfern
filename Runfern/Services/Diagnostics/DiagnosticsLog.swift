import Foundation
import Synchronization

/// One diagnostic event. Messages are redacted before they are stored.
nonisolated struct DiagnosticEntry: Codable, Hashable, Identifiable, Sendable {
    enum Level: String, Codable, Sendable { case info, warning, error }
    enum Category: String, Codable, Sendable { case runtime, provisioning, sync, catalog, storage, app }

    var id: String { "\(date.timeIntervalSince1970)-\(category.rawValue)-\(message)" }
    let date: Date
    let level: Level
    let category: Category
    let message: String
}

/// Local, size-limited diagnostic journal. Nothing leaves the device unless the
/// person explicitly shares a support report.
nonisolated final class DiagnosticsLog: Sendable {
    static let shared = DiagnosticsLog(fileURL: AppPaths.diagnostics)

    /// Keeps the journal small; older entries move to a single rotated file.
    static let maximumFileSize = 256 * 1024

    private let fileURL: URL
    private let lock = Mutex(())

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func record(_ level: DiagnosticEntry.Level, _ category: DiagnosticEntry.Category, _ message: String) {
        shared.record(level, category, message)
    }

    func record(_ level: DiagnosticEntry.Level, _ category: DiagnosticEntry.Category, _ message: String) {
        let entry = DiagnosticEntry(date: .now, level: level, category: category, message: Redactor.redact(message))
        #if DEBUG
        print("[diagnostics \(entry.date.formatted(.dateTime.hour().minute().second()))] \(category.rawValue): \(entry.message)")
        #endif
        guard let line = try? AgentCoding.encodeLine(entry.encodedForStorage) else { return }
        lock.withLock { _ in
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: fileURL.path(percentEncoded: false))[.size] as? Int,
               size > Self.maximumFileSize {
                let rotated = rotatedURL
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: fileURL, to: rotated)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// Newest entries first.
    func entries(limit: Int = 500) -> [DiagnosticEntry] {
        lock.withLock { _ in
            let data = [rotatedURL, fileURL].compactMap { try? Data(contentsOf: $0) }.reduce(Data(), +)
            let entries = data.split(separator: 0x0A).compactMap { line in
                try? JSONDecoder.diagnostics.decode(DiagnosticEntry.self, from: Data(line))
            }
            return Array(entries.suffix(limit).reversed())
        }
    }

    func clear() {
        lock.withLock { _ in
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: rotatedURL)
        }
    }

    private var rotatedURL: URL { fileURL.deletingPathExtension().appendingPathExtension("1.jsonl") }
}

nonisolated extension DiagnosticEntry.Level {
    /// The level as the diagnostics page names it; `rawValue` stays in the support report.
    var title: String {
        switch self {
        case .info: String(localized: "diagnostics.level.info", defaultValue: "Information")
        case .warning: String(localized: "diagnostics.level.warning", defaultValue: "Warning")
        case .error: String(localized: "diagnostics.level.error", defaultValue: "Error")
        }
    }
}

nonisolated extension DiagnosticEntry.Category {
    /// The category as the diagnostics page names it; `rawValue` stays in the support report.
    var title: String {
        switch self {
        case .runtime: String(localized: "diagnostics.category.runtime", defaultValue: "Linux")
        case .provisioning: String(localized: "diagnostics.category.provisioning", defaultValue: "Setup")
        case .sync: String(localized: "diagnostics.category.sync", defaultValue: "Sync")
        case .catalog: String(localized: "diagnostics.category.catalog", defaultValue: "Catalog")
        case .storage: String(localized: "diagnostics.category.storage", defaultValue: "Storage")
        case .app: String(localized: "diagnostics.category.app", defaultValue: "App")
        }
    }
}

private nonisolated extension DiagnosticEntry {
    /// Dates are stored as ISO 8601 strings so the journal stays human-readable.
    var encodedForStorage: StoredEntry {
        StoredEntry(date: ISO8601DateFormatter().string(from: date), level: level, category: category, message: message)
    }

    struct StoredEntry: Encodable {
        let date: String
        let level: Level
        let category: Category
        let message: String
    }
}

nonisolated extension JSONDecoder {
    static var diagnostics: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
