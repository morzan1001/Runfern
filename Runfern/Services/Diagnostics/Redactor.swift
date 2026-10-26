import Foundation

/// Removes secrets and personal data from diagnostic text (SET02, SET04, T16).
/// Applied when an entry is written and again when a support report is built.
nonisolated enum Redactor {
    private static let rules: [(pattern: String, replacement: String)] = [
        // PEM private keys, including OpenSSH keys.
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[private key]"),
        // Authorization headers and bearer tokens.
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 [secret]"),
        // GitHub, GitLab, and similar personal access tokens.
        (#"\b(ghp|gho|ghu|ghs|ghr|github_pat|glpat)_[A-Za-z0-9_]{10,}"#, "[token]"),
        // AWS access key IDs.
        (#"\bAKIA[0-9A-Z]{16}\b"#, "[token]"),
        // key=value pairs whose key names a secret.
        (#"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|auth)(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s&,;]+)"#, "$1$2[secret]"),
        // Credentials embedded in URLs.
        (#"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, "$1[credentials]@"),
        // Per-installation container paths and user home directories.
        (#"/(private/)?var/mobile/Containers/[A-Za-z]+/[A-Za-z]+/[0-9A-F-]{36}"#, "<app container>"),
        (#"/Users/[^/\s]+"#, "/Users/<user>"),
        // E-mail addresses.
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
    ]

    private static let compiled: [(NSRegularExpression, String)] = rules.map {
        (try! NSRegularExpression(pattern: $0.pattern), $0.replacement)
    }

    static func redact(_ text: String) -> String {
        compiled.reduce(text) { result, rule in
            rule.0.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.1)
        }
    }
}
