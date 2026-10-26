import CryptoKit
import Foundation

/// Per-session secret that protects the local IDE endpoint (Plan 4.8).
nonisolated enum SessionToken {
    /// 256 random bits, URL-safe Base64 without padding.
    static func generate() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
