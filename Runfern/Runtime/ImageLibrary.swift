import Foundation
import Observation

/// Manages shared, immutable base images (Plan 4.2, OFF02, IMG02).
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

    /// Mirrors the global setting “Large downloads over Wi-Fi only” (OFF05).
    var allowsExpensiveNetwork = false

    private var transient: [String: Status] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]

    func status(of image: BaseImage) -> Status {
        if let status = transient[image.id] { return status }
        if FileManager.default.fileExists(atPath: AppPaths.image(image.id, version: image.catalogVersion).path(percentEncoded: false)) { return .available }
        guard image.source != nil else { return .notPublished }
        return FileManager.default.fileExists(atPath: resumeDataURL(image).path(percentEncoded: false)) ? .partial : .missing
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
            transient[image.id] = nil
        } catch {
            transient[image.id] = (error as? URLError)?.code == .cancelled ? nil : .failed(error.localizedDescription)
            throw error
        }
    }

    /// Cancels a download; data already received is kept for resuming.
    func cancel(_ image: BaseImage) {
        tasks[image.id]?.cancel { [name = Self.directoryName(image)] data in
            if let data { try? data.write(to: Self.resumeDataURLStatic(name)) }
        }
    }

    /// Removes bases no environment references anymore (PRJ06, DAT07). Returns the space freed.
    @discardableResult
    func removeUnreferenced(keeping referenced: Set<String>) -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: AppPaths.images, includingPropertiesForKeys: nil) else { return 0 }
        var freed: Int64 = 0
        for bundle in files where !referenced.contains(bundle.lastPathComponent) {
            freed += DiskUsage.allocatedSize(of: bundle)
            try? ImageBundle.remove(bundle)
        }
        if let partials = try? fm.contentsOfDirectory(at: AppPaths.downloads, includingPropertiesForKeys: nil) {
            for file in partials where !referenced.contains(file.deletingPathExtension().lastPathComponent) {
                freed += DiskUsage.allocatedSize(of: file)
                try? fm.removeItem(at: file)
            }
        }
        return freed
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
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
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
