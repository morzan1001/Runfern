import Foundation

/// Storage checks and reporting (DAT01/DAT02).
nonisolated enum DiskUsage {
    enum SpaceError: LocalizedError {
        case insufficient(needed: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case let .insufficient(needed, available):
                String(localized: "Not enough storage: \(needed.formattedBytes) needed, \(available.formattedBytes) available. Free up space in Settings or remove data you no longer need.")
            }
        }
    }

    /// Headroom so the system and in-flight writes never hit the limit.
    static let reserve: Int64 = 512 * 1024 * 1024

    static var availableCapacity: Int64 {
        let values = try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func ensureAvailable(_ bytes: Int64) throws {
        let available = availableCapacity
        guard available >= bytes + reserve else {
            throw SpaceError.insufficient(needed: bytes + reserve, available: available)
        }
    }

    /// Space actually allocated by a folder or file.
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
