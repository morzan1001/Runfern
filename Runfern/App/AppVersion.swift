import Foundation

enum AppVersion {
    static var display: String {
        display(info: Bundle.main.infoDictionary ?? [:])
    }

    static func display(info: [String: Any]) -> String {
        guard let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            DiagnosticsLog.record(.error, .app, "The app bundle has no release version.")
            return String(localized: "Version unavailable")
        }
        return "v\(version)"
    }
}
