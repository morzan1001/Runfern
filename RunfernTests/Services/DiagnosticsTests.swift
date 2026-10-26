import Foundation
import Testing
@testable import Runfern

/// Verifies that diagnostics never keep secrets (SET02, SET04, test scenario T16).
@Suite struct DiagnosticsTests {
    @Test(arguments: [
        ("Authorization: Bearer abcdefghijklmnop123", "abcdefghijklmnop123"),
        ("push failed with ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
        ("key AKIAABCDEFGHIJKLMNOP used", "AKIAABCDEFGHIJKLMNOP"),
        ("password=hunter2 token: s3cr3t", "hunter2"),
        ("remote https://alice:pa55@example.com/repo.git", "pa55"),
        ("opened /Users/alice/Projects/app", "alice"),
        ("contact alice@example.com", "alice@example.com"),
        ("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAB3Nza\n-----END OPENSSH PRIVATE KEY-----", "AAAAB3Nza"),
    ])
    func secretsAreRedacted(input: String, secret: String) {
        #expect(!Redactor.redact(input).contains(secret))
    }

    @Test func harmlessTextStaysReadable() {
        let text = "Step installToolchains failed: The Linux environment did not respond in time."
        #expect(Redactor.redact(text) == text)
    }

    @Test func journalStoresRedactedEntriesNewestFirst() {
        let log = DiagnosticsLog(fileURL: URL.temporaryDirectory.appending(path: "diag-\(UUID().uuidString).jsonl"))
        log.record(.info, .runtime, "first")
        log.record(.error, .sync, "token=abc123secret")

        let entries = log.entries()

        #expect(entries.map(\.message) == ["token=[secret]", "first"])
        #expect(entries.first?.level == .error)
        log.clear()
        #expect(log.entries().isEmpty)
    }

    @Test func supportReportContainsNoProjectData() {
        let context = SupportReport.Context(environmentStates: ["ready", "ready", "failed"], bindingStates: ["localFolder/granted"],
                                            catalogVersion: 1, isSimulatedRuntime: true)
        let entry = DiagnosticEntry(date: .now, level: .error, category: .sync, message: "Bearer abcdefghijkl")

        let report = SupportReport.make(context: context, entries: [entry], deviceModel: "iPad", systemVersion: "iPadOS 27")

        #expect(report.contains("ready=2"))
        #expect(report.contains("failed=1"))
        #expect(!report.contains("abcdefghijkl"))
    }
}
