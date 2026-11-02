import SwiftUI
import Synchronization

private nonisolated struct LicenseNotice: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let version: String
    let license: String
    let role: String
    let file: String
    let jitOnly: Bool

    func loadText() -> LicenseNoticeText {
        guard let url = licenseResource(file) else {
            DiagnosticsLog.record(.error, .app, "Required license notice is missing: \(file)")
            return .missing
        }
        do {
            return .loaded(try String(contentsOf: url, encoding: .utf8))
        } catch {
            DiagnosticsLog.record(.error, .app, "Reading license notice \(file) failed: \(error.localizedDescription)")
            return .missing
        }
    }
}

private nonisolated enum LicenseNoticeText: Sendable {
    case loaded(String)
    case missing
}

private nonisolated final class LicenseTextCache: Sendable {
    static let shared = LicenseTextCache()
    private let storage = Mutex<[String: LicenseNoticeText]>([:])

    func load(_ notice: LicenseNotice) throws -> LicenseNoticeText {
        try storage.withLock { cache in
            try Task.checkCancellation()
            if let cached = cache[notice.file] { return cached }
            let text = notice.loadText()
            cache[notice.file] = text
            return text
        }
    }
}

private nonisolated struct LicenseSearchResult: Sendable {
    let notices: [LicenseNotice]
    let hasMissingNotices: Bool
}

private nonisolated struct LicenseIndex: Decodable, Sendable {
    let notices: [LicenseNotice]
    let status: String
    let blockers: [String]

    static func load() -> LicenseIndex? {
        guard let url = licenseResource("license-index.json") else {
            DiagnosticsLog.record(.error, .app, "Required license index is missing.")
            return nil
        }
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch {
            DiagnosticsLog.record(.error, .app, "Loading the license index failed: \(error.localizedDescription)")
            return nil
        }
    }
}

// Synchronized Xcode groups may flatten resources or preserve folder structure.
private nonisolated func licenseResource(_ filename: String) -> URL? {
    for directory in [nil, "Licenses", "Resources/Licenses"] as [String?] {
        if let url = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: directory) {
            return url
        }
    }
    return nil
}

private nonisolated func licenseWorkerValue<Value: Sendable>(_ worker: Task<Value, Error>) async throws -> Value {
    try await withTaskCancellationHandler {
        try await worker.value
    } onCancel: {
        worker.cancel()
    }
}

struct ComponentsView: View {
    @State private var query = ""
    @State private var matchingNotices: [LicenseNotice]?
    @State private var completedQuery: String?
    @State private var hasMissingNotices = false
    private let index = LicenseIndex.load()

    private var notices: [LicenseNotice] {
        (index?.notices ?? []).filter { notice in
            #if RUNFERN_JIT
            return true
            #else
            return !notice.jitOnly
            #endif
        }
    }

    var body: some View {
        List {
            if index == nil {
                Text("License notices are missing or unreadable. This build must not be distributed.")
                    .foregroundStyle(.red)
            } else if index?.status != "VERIFIED" {
                Section("Release compliance") {
                    Text("Release license verification is blocked. Notices below contain audited source texts, not legal clearance.")
                    NavigationLink("Unresolved license findings") {
                        List(index?.blockers ?? [], id: \.self) { Text($0).textSelection(.enabled) }
                            .navigationTitle("License findings")
                    }
                }
            }
            if hasMissingNotices {
                Text("Required license notice is missing or unreadable. This build must not be distributed.")
                    .foregroundStyle(.red)
            }
            Section("Third-party notices") {
                if index != nil && completedQuery != query {
                    ProgressView("Searching license notices")
                }
                ForEach(matchingNotices ?? notices) { notice in
                    NavigationLink {
                        LicenseNoticeView(notice: notice)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notice.name).font(.headline)
                            Text(notice.version).font(.caption)
                            Text(notice.role).font(.subheadline)
                            Text(notice.license).font(.caption).foregroundStyle(.secondary)
                            if notice.jitOnly {
                                Text("JIT sideload only").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Corresponding source") {
                Text("QEMU and linked libraries have source and redistribution obligations. Release distributors must provide the exact verified corresponding-source bundle alongside the binary. No-JIT builds still contain GPL/LGPL components.")
                Text("Downloaded Linux guests, editors and toolchains are separate distributions with their own notices and source obligations.")
            }
        }
        .searchable(text: $query, prompt: "Search components, licenses and notice text")
        .navigationTitle("Components and Licenses")
        .task(id: query) {
            guard index != nil else { return }
            let candidates = notices
            let searchQuery = query
            let worker = Task.detached(priority: .userInitiated) {
                var matches: [LicenseNotice] = []
                var missing = false
                for notice in candidates {
                    try Task.checkCancellation()
                    let content = try LicenseTextCache.shared.load(notice)
                    let textMatches: Bool
                    switch content {
                    case .loaded(let text):
                        textMatches = !searchQuery.isEmpty && text.localizedCaseInsensitiveContains(searchQuery)
                    case .missing:
                        missing = true
                        textMatches = false
                    }
                    if searchQuery.isEmpty || textMatches
                        || "\(notice.name) \(notice.version) \(notice.license) \(notice.role)"
                            .localizedCaseInsensitiveContains(searchQuery) {
                        matches.append(notice)
                    }
                }
                try Task.checkCancellation()
                return LicenseSearchResult(notices: matches, hasMissingNotices: missing)
            }
            do {
                let result = try await licenseWorkerValue(worker)
                guard !Task.isCancelled else { return }
                matchingNotices = result.notices
                hasMissingNotices = result.hasMissingNotices
                completedQuery = searchQuery
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                hasMissingNotices = true
                completedQuery = searchQuery
                DiagnosticsLog.record(.error, .app, "Searching license notices failed: \(error.localizedDescription)")
            }
        }
    }
}

private struct LicenseNoticeView: View {
    let notice: LicenseNotice
    @State private var query = ""
    @State private var content: LicenseNoticeText?
    @State private var cachedParagraphs: [String] = []

    private var paragraphs: [String] {
        query.isEmpty ? cachedParagraphs : cachedParagraphs.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            switch content {
            case nil:
                ProgressView("Loading license notice").padding()
            case .missing:
                Text("Required license notice is missing or unreadable. This build must not be distributed.")
                    .foregroundStyle(.red)
                    .padding()
            case .loaded:
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
        }
        .searchable(text: $query, prompt: "Find in this notice")
        .navigationTitle(notice.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: notice.id) {
            let candidate = notice
            let worker = Task.detached(priority: .userInitiated) {
                let content = try LicenseTextCache.shared.load(candidate)
                let paragraphs: [String]
                switch content {
                case .loaded(let text):
                    paragraphs = text.components(separatedBy: "\n\n")
                case .missing:
                    paragraphs = []
                }
                try Task.checkCancellation()
                return (content, paragraphs)
            }
            do {
                let result = try await licenseWorkerValue(worker)
                guard !Task.isCancelled else { return }
                content = result.0
                cachedParagraphs = result.1
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                content = .missing
                DiagnosticsLog.record(.error, .app, "Loading license notice \(candidate.file) failed: \(error.localizedDescription)")
            }
        }
    }
}
