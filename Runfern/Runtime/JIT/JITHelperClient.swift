#if RUNFERN_JIT
import Darwin
import Foundation

/// The private NSExtension calls that start one of the app's own extensions (the same ones Husk and
/// LiveContainer use). Compiled only into builds for sideloading. `send` checks that every one
/// exists before using any, so a missing one ends the attempt with an error instead of an
/// unrecognized selector.
@objc private protocol NSExtensionFactory {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol NSExtensionRequesting {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(cancelExtensionRequestWithIdentifier:)
    func cancelExtensionRequest(withIdentifier identifier: NSUUID)
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}

/// The instance methods of `NSExtensionRequesting`, by selector.
private let requestingSelectors = ["beginExtensionRequestWithInputItems:completion:", "cancelExtensionRequestWithIdentifier:",
                                   "setRequestCompletionBlock:", "setRequestCancellationBlock:", "setRequestInterruptionBlock:"]

/// Starts the JIT helper extension (PlugIns/RunfernJITHelper.appex) with one request and returns
/// its answer. Cancelling the calling task ends the helper's request.
///
/// The helper is found by the bundle identifier it has in this installation, so re-signing tools
/// that rename identifiers don't break the lookup. Adapted from Husk (GPL-2.0-or-later).
@MainActor
enum JITHelperClient {
    enum ClientError: LocalizedError {
        case missingHelper
        case missingAppGroup
        case unavailable
        case didNotStart
        case stopped(String)
        case noAnswer

        var errorDescription: String? {
            switch self {
            case .missingHelper: String(localized: "The JIT helper is missing from this installation.")
            case .missingAppGroup: String(localized: "Runfern and its JIT helper share no app group in this installation.")
            case .unavailable: String(localized: "iPadOS did not provide the extension interface the JIT helper needs.")
            case .didNotStart: String(localized: "The JIT helper did not start.")
            case .stopped(let reason): String(localized: "The JIT helper stopped: \(reason)")
            case .noAnswer: String(localized: "The JIT helper finished without an answer.")
            }
        }
    }

    /// The helper's answer to a request.
    typealias Response = JITProtocol.Answer

    static var isInstalled: Bool { helperIdentifier != nil }

    private static var helperIdentifier: String? {
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appending(path: "RunfernJITHelper.appex"))?.bundleIdentifier }
    }

    /// Requests in flight, kept alive until they end.
    private static var running: [Request] = []

    /// Sends `request` (keys in `JITProtocol.Key`) to the helper.
    static func send(_ request: [String: Any]) async throws -> Response {
        guard let identifier = helperIdentifier else { throw ClientError.missingHelper }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension"),
              class_getClassMethod(extensionClass, NSSelectorFromString("extensionWithIdentifier:error:")) != nil else {
            throw ClientError.unavailable
        }
        let factory = unsafeBitCast(extensionClass as AnyObject, to: NSExtensionFactory.self)
        let found = try factory.extension(withIdentifier: identifier)
        let foundClass: AnyClass? = object_getClass(found)
        for name in requestingSelectors where class_getInstanceMethod(foundClass, NSSelectorFromString(name)) == nil {
            throw ClientError.unavailable
        }
        let requesting = unsafeBitCast(found, to: NSExtensionRequesting.self)
        let pending = Request(extension: found, requesting: requesting)
        running.append(pending)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.begin(userInfo: request, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in pending.cancel() }
        }
    }

    fileprivate static func finished(_ request: Request) {
        running.removeAll { $0 === request }
    }

    /// One request, from its start to its single result.
    fileprivate final class Request {
        private let `extension`: AnyObject
        private let requesting: NSExtensionRequesting
        private var continuation: CheckedContinuation<Response, Error>?
        private var identifier: NSUUID?
        private var isCancelled = false

        init(extension found: AnyObject, requesting: NSExtensionRequesting) {
            self.extension = found
            self.requesting = requesting
        }

        /// Whether a callback with `identifier` belongs to this request. Until the helper has
        /// started, the request's identifier is unknown and every callback is taken as its own.
        private func isMine(_ identifier: NSUUID?) -> Bool {
            guard let own = self.identifier, let identifier else { return true }
            return own.isEqual(identifier)
        }

        func begin(userInfo: [String: Any], continuation: CheckedContinuation<Response, Error>) {
            self.continuation = continuation
            requesting.setRequestCompletionBlock({ [weak self] identifier, items in
                let response = Response(userInfo: (items?.first as? NSExtensionItem)?.userInfo)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isMine(identifier) else { return }
                        self.end(response.map(Result.success) ?? .failure(ClientError.noAnswer))
                    }
                }
            })
            requesting.setRequestCancellationBlock({ [weak self] identifier, error in
                let reason = error?.localizedDescription ?? "canceled"
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isMine(identifier) else { return }
                        self.end(.failure(ClientError.stopped(reason)))
                    }
                }
            })
            requesting.setRequestInterruptionBlock({ [weak self] identifier in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isMine(identifier) else { return }
                        self.end(.failure(ClientError.stopped("interrupted")))
                    }
                }
            })
            let item = NSExtensionItem()
            item.userInfo = userInfo
            requesting.beginExtensionRequest(withInputItems: [item], completion: { [weak self] identifier in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard let identifier else { return self.end(.failure(ClientError.didNotStart)) }
                        self.identifier = identifier
                        if self.isCancelled { self.cancel() }
                    }
                }
            })
        }

        /// Ends the helper's request. Before the helper has started, the request stays alive until
        /// its identifier arrives, and is cancelled then.
        func cancel() {
            isCancelled = true
            resume(.failure(CancellationError()))
            guard let identifier else { return }
            requesting.cancelExtensionRequest(withIdentifier: identifier)
            JITHelperClient.finished(self)
        }

        private func end(_ result: Result<Response, Error>) {
            resume(result)
            JITHelperClient.finished(self)
        }

        private func resume(_ result: Result<Response, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}
#endif
