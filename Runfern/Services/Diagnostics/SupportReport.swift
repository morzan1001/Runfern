import Foundation

/// Support report that is only created on the person's request (SET02, SET04).
/// Contains technical states and redacted events; no project names, paths, or source code.
nonisolated enum SupportReport {
    struct Context: Sendable {
        let environmentStates: [String]
        let bindingStates: [String]
        let catalogVersion: Int
        let isSimulatedRuntime: Bool
    }

    static func make(context: Context, entries: [DiagnosticEntry], deviceModel: String, systemVersion: String) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Runfern support report",
            "Created: \(formatter.string(from: .now))",
            "App: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "Device: \(deviceModel), \(systemVersion)",
            "Catalog version: \(context.catalogVersion)",
            "Runtime: \(context.isSimulatedRuntime ? "simulated" : "emulated")",
            "Environments: \(summary(of: context.environmentStates))",
            "Folder access: \(summary(of: context.bindingStates))",
            "",
            "Events (newest first):",
        ]
        lines += entries.map {
            "\(formatter.string(from: $0.date)) [\($0.level.rawValue)] \($0.category.rawValue): \(Redactor.redact($0.message))"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the report into a temporary file for sharing.
    static func write(_ report: String) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "Runfern-Support-\(Int(Date.now.timeIntervalSince1970)).txt")
        try report.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func summary(of states: [String]) -> String {
        guard !states.isEmpty else { return "none" }
        return Dictionary(grouping: states, by: { $0 }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ")
    }
}
