import Foundation

/// Minimal client for the QEMU Machine Protocol: capability negotiation, commands, and the
/// few events Runfern reacts to. Replies are matched to commands by their `id`.
actor QMPClient {
    enum QMPError: LocalizedError {
        case failed(String)
        case disconnected

        var errorDescription: String? {
            switch self {
            case .failed(let message): "QEMU: \(message)"
            case .disconnected: String(localized: "The connection to the virtual machine was lost.")
            }
        }
    }

    private let transport: AgentTransport
    private var framer = LineFramer()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<String?, Error>] = [:]
    private var greeting: CheckedContinuation<Void, Error>?
    private var greeted = false
    private var reader: Task<Void, Never>?
    private var isClosed = false

    init(transport: AgentTransport) {
        self.transport = transport
    }

    /// Waits for the greeting and leaves negotiation mode. A QEMU that does not answer in time is
    /// treated as disconnected, so callers never wait forever.
    func connect(timeout: Duration = .seconds(30)) async throws {
        reader = Task { await self.readLoop() }
        if !greeted {
            guard !isClosed else { throw QMPError.disconnected }
            let watchdog = Task { [transport] in
                try await Task.sleep(for: timeout)
                transport.close()
            }
            defer { watchdog.cancel() }
            try await withCheckedThrowingContinuation { greeting = $0 }
        }
        _ = try await execute("qmp_capabilities")
    }

    /// Returns the command's result: text as is (human monitor commands), anything else as JSON.
    @discardableResult
    func execute(_ command: String, arguments: [String: String]? = nil,
                 timeout: Duration = .seconds(30)) async throws -> String? {
        try await send(command, arguments: arguments, timeout: timeout)
    }

    /// Variant for nested arguments such as a `blockdev-add` node, given as a JSON object.
    @discardableResult
    func execute(_ command: String, json arguments: String, timeout: Duration = .seconds(30)) async throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(arguments.utf8))
        return try await send(command, arguments: object, timeout: timeout)
    }

    /// The VM's run state, for example `running`, `shutdown`, or `prelaunch`.
    func status() async throws -> String {
        let result = try await execute("query-status") ?? "{}"
        let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        return object?["status"] as? String ?? "unknown"
    }

    private func send(_ command: String, arguments: Any?, timeout: Duration) async throws -> String? {
        guard !isClosed else { throw QMPError.disconnected }
        let id = nextID
        nextID += 1
        var message: [String: Any] = ["execute": command, "id": id]
        if let arguments { message["arguments"] = arguments }
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            self.fail(id, QMPError.failed("\(command) timed out"))
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await transport.send(line) } catch { self.fail(id, error) }
            }
        }
    }

    /// Runs a human monitor command, for example `hostfwd_add`. Errors are reported as text.
    func humanMonitor(_ commandLine: String) async throws {
        let output = try await execute("human-monitor-command", arguments: ["command-line": commandLine]) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { throw QMPError.failed(trimmed) }
    }

    func close() {
        transport.close()
    }

    private static func text(of value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func readLoop() async {
        do {
            for try await chunk in transport.incoming {
                for line in try framer.append(chunk) where !line.isEmpty {
                    handle(line)
                }
            }
        } catch {}
        isClosed = true
        greeting?.resume(throwing: QMPError.disconnected)
        greeting = nil
        for continuation in pending.values { continuation.resume(throwing: QMPError.disconnected) }
        pending.removeAll()
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if message["QMP"] != nil {
            greeted = true
            greeting?.resume()
            greeting = nil
        } else if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: QMPError.failed(error["desc"] as? String ?? "unknown error"))
            } else {
                continuation.resume(returning: Self.text(of: message["return"]))
            }
        }
        // Events such as SHUTDOWN need no handling: the launcher observes QEMU's exit directly.
    }
}
