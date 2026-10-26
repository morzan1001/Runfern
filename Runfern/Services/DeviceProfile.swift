import Foundation

/// Capabilities of this iPad relevant for local Linux environments (Plan 2.1, D01).
/// The exact minimum device class is decided after the on-device measurements (P1); until then
/// Runfern targets iPads with an M-series chip, which have at least 8 GB of memory and 8 cores.
nonisolated struct DeviceProfile: Sendable {
    let modelIdentifier: String
    let physicalMemory: UInt64
    let processorCount: Int
    let systemVersion: String

    static let minimumMemory: UInt64 = 8 * 1024 * 1024 * 1024
    static let minimumProcessorCount = 8

    static var current: DeviceProfile {
        let info = ProcessInfo.processInfo
        return DeviceProfile(modelIdentifier: modelIdentifier(), physicalMemory: info.physicalMemory,
                             processorCount: info.activeProcessorCount, systemVersion: info.operatingSystemVersionString)
    }

    /// Whether this device belongs to the planned target class.
    var meetsTarget: Bool {
        physicalMemory >= Self.minimumMemory && processorCount >= Self.minimumProcessorCount
    }

    var supportedProfiles: [ResourceProfile] {
        ResourceProfile.allCases.filter { $0.isSupported(physicalMemory: physicalMemory, processorCount: processorCount) }
    }

    var memoryDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(physicalMemory), countStyle: .memory)
    }

    private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
