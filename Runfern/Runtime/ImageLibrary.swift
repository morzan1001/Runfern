import Foundation
import Observation

/// Manages shared, immutable base images.
/// Downloads can be resumed; an image counts as available only after its checksum has been verified.
@Observable
final class ImageLibrary {
    enum Status: Equatable {
        case notPublished           // listed in the catalog without a published source
        case missing
        case downloading(Double)
        case partial                // interrupted, can be resumed
        case verifying
        case available
        case failed(String)

        var title: String {
            switch self {
            case .notPublished: String(localized: "Not published yet")
            case .missing: String(localized: "Not downloaded")
            case .downloading(let fraction): String(localized: "Downloading (\(fraction.formatted(.percent.precision(.fractionLength(0)))))")
            case .partial: String(localized: "Partially downloaded")
            case .verifying: String(localized: "Verifying")
            case .available: String(localized: "Verified and available")
            case .failed(let message): String(localized: "Error: \(message)")
            }
        }
    }

    enum LibraryError: LocalizedError {
        case notPublished(String)
        case integrityFailed(String)
        case offline

        var errorDescription: String? {
            switch self {
            case .notPublished(let name): String(localized: "\(name) has not been published for download yet.")
            case .integrityFailed(let name): String(localized: "The checksum of \(name) does not match. The file was discarded and not registered.")
            case .offline: String(localized: "This download requires an internet connection. Local projects remain usable.")
            }
        }
    }

    /// Mirrors the global setting “Large downloads over Wi-Fi only”.
    var allowsExpensiveNetwork = false

    /// The simulated runtime downloads nothing, so it can offer every base the catalog lists.
    private let offersUnpublished: Bool
    private var transient: [String: Status] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// Changes whenever a base is installed or removed. `status(of:)` reads it, so screens that
    /// show a base's state re-render once the files on disk have changed, not before.
    private var installRevision = 0

    init(offersUnpublished: Bool = false) {
        self.offersUnpublished = offersUnpublished
    }

    func status(of image: BaseImage) -> Status {
        _ = installRevision
        if let status = transient[image.id] { return status }
        if Self.isInstalled(image) { return .available }
        guard image.source != nil else { return .notPublished }
        return FileManager.default.fileExists(atPath: resumeDataURL(image).path(percentEncoded: false)) ? .partial : .missing
    }

    /// Whether a project can be set up with this base: it is published for download or already on
    /// this iPad. The catalog also lists bases that are planned but not published yet; those are
    /// not offered for new projects and presets.
    func isOffered(_ image: BaseImage) -> Bool {
        offersUnpublished || image.source != nil || status(of: image) == .available
    }

    /// The bases of `bases` that `isOffered`, in their order. Screens pass `CatalogStore.baseImages`,
    /// so they update when a newer catalog arrives.
    func offered(_ bases: [BaseImage]) -> [BaseImage] {
        bases.filter { isOffered($0) }
    }

    /// The base a new project or preset starts with: the first one that is published or installed,
    /// otherwise the catalog's first, so a selection always exists. Static, so a view can choose it
    /// in its initializer, before the environment is available.
    nonisolated static var preferredBase: BaseImage? {
        Catalog.baseImages.first { $0.source != nil || isInstalled($0) } ?? Catalog.baseImages.first
    }

    nonisolated static func isInstalled(_ image: BaseImage) -> Bool {
        FileManager.default.fileExists(atPath: AppPaths.image(image.id, version: image.catalogVersion).path(percentEncoded: false))
    }

    /// Downloads the image if needed, verifies it, and stores it as immutable.
    func ensureAvailable(_ image: BaseImage, isOnline: Bool) async throws {
        if status(of: image) == .available { return }
        guard let source = image.source else { throw LibraryError.notPublished(image.displayName) }
        guard isOnline else { throw LibraryError.offline }
        // The archive and its unpacked files briefly exist side by side.
        try DiskUsage.ensureAvailable(image.downloadSizeBytes * 2)

        transient[image.id] = .downloading(0)
        do {
            let downloaded = try await download(image, from: source.url)
            transient[image.id] = .verifying
            guard try await VerifiedDownload.verify(downloaded, sha256: source.sha256) else {
                throw LibraryError.integrityFailed(image.displayName)
            }
            // Bases are immutable; changes only ever go into the environment's overlay.
            try await Task.detached(priority: .utility) {
                defer { try? FileManager.default.removeItem(at: downloaded) }
                try ImageBundle.install(archive: downloaded, to: AppPaths.image(image.id, version: image.catalogVersion))
            }.value
            installRevision += 1
            transient[image.id] = nil
        } catch {
            transient[image.id] = (error as? URLError)?.code == .cancelled ? nil : .failed(error.localizedDescription)
            throw error
        }
    }

    /// Removes an installed base and any partial download of it. Callers make sure no environment
    /// builds on it (`ProjectStore.referencedImageDirectories`). The directory moves aside, so the
    /// base reads as not downloaded once this returns; its files go in the background.
    func remove(_ image: BaseImage) async throws {
        let directory = AppPaths.image(image.id, version: image.catalogVersion)
        let resumeData = resumeDataURL(image)
        // Also when the move fails: the resume data may be gone already.
        defer {
            transient[image.id] = nil
            installRevision += 1
        }
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.removeItem(at: resumeData)
            guard fm.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
            try fm.createDirectory(at: AppPaths.trash, withIntermediateDirectories: true)
            let aside = AppPaths.trash.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try fm.moveItem(at: directory, to: aside)
            // Bases are installed immutable; ImageBundle.remove lifts that first.
            Task.detached(priority: .background) { try? ImageBundle.remove(aside) }
        }.value
    }

    /// Cancels a download; data already received is kept for resuming.
    func cancel(_ image: BaseImage) {
        tasks[image.id]?.cancel { [name = Self.directoryName(image)] data in
            if let data { try? data.write(to: Self.resumeDataURLStatic(name)) }
        }
    }

    // MARK: Download

    private func download(_ image: BaseImage, from url: URL) async throws -> URL {
        let configuration = VerifiedDownload.configuration(allowsExpensiveNetwork: allowsExpensiveNetwork)
        let delegate = DownloadDelegate { [weak self] fraction in
            Task { @MainActor [weak self] in self?.transient[image.id] = .downloading(fraction) }
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let resumeURL = resumeDataURL(image)
        let task: URLSessionDownloadTask
        if let resumeData = try? Data(contentsOf: resumeURL) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: url)
        }
        tasks[image.id] = task
        defer { tasks[image.id] = nil }

        do {
            let location = try await delegate.run(task)
            try? FileManager.default.removeItem(at: resumeURL)
            return location
        } catch {
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeURL)
            }
            throw error
        }
    }

    private func resumeDataURL(_ image: BaseImage) -> URL { Self.resumeDataURLStatic(Self.directoryName(image)) }

    /// Partial downloads are named like the image directory, so cleanup can match both.
    private nonisolated static func directoryName(_ image: BaseImage) -> String {
        AppPaths.imageDirectoryName(image.id, version: image.catalogVersion)
    }

    private nonisolated static func resumeDataURLStatic(_ name: String) -> URL {
        AppPaths.downloads.appending(path: "\(name).resume")
    }
}

/// Bridges a download's progress and result into async/await.
private nonisolated final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    /// The last whole percent reported, so progress is forwarded at most once per step.
    private var lastPercent = -1   // guarded by `lock`
    private let lock = NSLock()

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func run(_ task: URLSessionDownloadTask) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // The UI shows whole percent, so finer steps would only flood the main actor with updates.
        let percent = Int(fraction * 100)
        let isNewStep = lock.withLock { () -> Bool in
            guard percent != self.lastPercent else { return false }
            self.lastPercent = percent
            return true
        }
        if isNewStep { onProgress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears after this call, so move it into our own download folder right away.
        let target = AppPaths.downloads.appending(path: UUID().uuidString + ".part")
        do {
            try FileManager.default.createDirectory(at: AppPaths.downloads, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: target)
            finish(.success(target))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
