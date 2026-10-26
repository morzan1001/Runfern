import Foundation

/// Read-only access to Open VSX, the extension registry openvscode-server installs from.
nonisolated struct OpenVSXClient: Sendable {
    struct Summary: Decodable, Identifiable, Hashable, Sendable {
        let namespace: String
        let name: String
        let displayName: String?
        let description: String?
        let version: String?
        let downloadCount: Int?
        let verified: Bool?
        let files: Files?

        var id: String { "\(namespace).\(name)" }
        var title: String { displayName?.isEmpty == false ? displayName! : name }
    }

    struct Files: Decodable, Hashable, Sendable {
        let icon: URL?
        let readme: URL?
    }

    struct Details: Decodable, Sendable {
        let namespace: String
        let name: String
        let displayName: String?
        let description: String?
        let version: String?
        let license: String?
        let downloadCount: Int?
        let verified: Bool?
        let files: Files?

        var id: String { "\(namespace).\(name)" }
    }

    private struct SearchResult: Decodable {
        let extensions: [Summary]
    }

    static let base = URL(string: "https://open-vsx.org/api")!

    /// Matching extensions; without a query the most downloaded ones.
    func search(_ query: String, size: Int = 30) async throws -> [Summary] {
        var components = URLComponents(url: Self.base.appending(path: "-/search"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "size", value: "\(size)")]
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            items += [URLQueryItem(name: "sortBy", value: "downloadCount"), URLQueryItem(name: "sortOrder", value: "desc")]
        } else {
            items.append(URLQueryItem(name: "query", value: trimmed))
        }
        components.queryItems = items
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(SearchResult.self, from: data).extensions
    }

    func details(of id: String) async throws -> Details {
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: Self.base.appending(path: parts[0]).appending(path: parts[1]))
        return try JSONDecoder().decode(Details.self, from: data)
    }

    func readme(at url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }
}
