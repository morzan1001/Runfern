import Foundation

/// The folder holding a project's files, accessible while this object is alive: the selected folder
/// itself for mounted folders, otherwise the working copy inside the app.
nonisolated final class WorkspaceFiles: Sendable {
    let url: URL
    private let isSecurityScoped: Bool

    init(_ binding: WorkspaceBinding) throws {
        if binding.storageMode == .mountedFolder {
            url = try WorkspaceAccess.resolve(binding)
            isSecurityScoped = url.startAccessingSecurityScopedResource()
            guard (try? url.checkResourceIsReachable()) == true else {
                if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
                throw WorkspaceAccess.AccessError.unavailable
            }
        } else {
            url = AppPaths.workingCopy(binding.id)
            isSecurityScoped = false
        }
    }

    deinit {
        if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
    }
}
