import Foundation

/// Security-scoped access to folders chosen by the user (Plan 4.4, FIL01–FIL03).
nonisolated enum WorkspaceAccess {
    enum AccessError: LocalizedError {
        case notAFolder
        case bookmarkFailed(String)
        case unavailable

        var errorDescription: String? {
            switch self {
            case .notAFolder: String(localized: "Please choose a folder.")
            case .bookmarkFailed(let reason): String(localized: "Access to the folder could not be saved: \(reason)")
            case .unavailable: String(localized: "The project folder is not reachable.")
            }
        }
    }

    /// Creates a binding from a fresh selection. Access is only opened for the duration of the call.
    static func makeBinding(for url: URL) throws -> WorkspaceBinding {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw AccessError.notAFolder
        }
        // Cloud files may not be downloaded yet, so only folders stored on the device are mounted directly.
        let isCloud = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return WorkspaceBinding(
                id: UUID(), storageMode: isCloud ? .localFolder : .mountedFolder, bookmark: data,
                displayPath: url.lastPathComponent,
                workspaceIdentity: normalizedIdentity(of: url),
                accessState: .granted
            )
        } catch {
            throw AccessError.bookmarkFailed(error.localizedDescription)
        }
    }

    /// Resolves the bookmark and checks whether the folder is reachable. Changes no data.
    static func check(_ binding: WorkspaceBinding) -> (state: AccessState, refreshedBookmark: Data?) {
        guard let bookmark = binding.bookmark else {
            return (binding.storageMode == .appInternal ? .granted : .unavailable, nil)
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return (.unavailable, nil)
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard (try? url.checkResourceIsReachable()) == true else { return (.unavailable, nil) }
        if isStale {
            return (.stale, try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        return (.granted, nil)
    }

    /// Resolves the stored folder reference. The caller opens and closes the security scope.
    static func resolve(_ binding: WorkspaceBinding) throws -> URL {
        var isStale = false
        guard let bookmark = binding.bookmark,
              let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        else { throw AccessError.unavailable }
        return url
    }

    /// Two folders collide if one is identical to or a subfolder of the other.
    static func overlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private static func normalizedIdentity(of url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
