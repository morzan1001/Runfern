#if DEBUG
import Foundation

/// Runs the app's main flow on a device without touching the UI, started with `-e2e-test`:
/// a project in a folder on the iPad (mounted directly), setup with Python, start, editor and
/// folder checks, a switch to a second project, reset, and removal. Uses its own project list.
@MainActor
enum EndToEndTest {
    static let argument = "-e2e-test"
    /// Only removes editor data in a fresh process, where no web view was created yet.
    static let removalArgument = "-e2e-removal-test"
    static var isRequested: Bool { [argument, removalArgument].contains(where: CommandLine.arguments.contains) }

    private static let log = TestLog("E2E")

    private static func step(_ message: String) {
        log.step(message)
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
        step("ok: \(message)")
    }

    static func run() async {
        if CommandLine.arguments.contains(removalArgument) {
            await IDEWebViewCache.shared.removeData(for: UUID())
            step("E2E PASSED: editor data removed without a web view")
            return
        }
        let store = ProjectStore(fileURL: URL.temporaryDirectory.appending(path: "e2e-\(UUID().uuidString).json"))
        let sync = SyncCenter()
        let images = ImageLibrary()
        let adapter = QEMUEmulatorAdapter()
        let provisioner = Provisioner(store: store, images: images, packages: PackageLibrary(), sync: sync,
                                      connectivity: Connectivity(), adapter: adapter)
        let runtime = RuntimeCoordinator(store: store, sync: sync, adapter: adapter)
        provisioner.releaseVM = { await runtime.release(for: $0) }
        images.allowsExpensiveNetwork = true
        step("backend: \(QEMUBackend.preferred.rawValue), debugger attached: \(JITSupport.isDebuggerAttached)")

        do {
            // 1. A folder on the iPad, mounted directly.
            let folder = URL.documentsDirectory.appending(path: "E2E-\(UUID().uuidString.prefix(4))", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("from the iPad".utf8).write(to: folder.appending(path: "hello.txt"))
            let binding = try WorkspaceAccess.makeBinding(for: folder)
            try check(binding.storageMode == .mountedFolder, "folder on the iPad is mounted directly")

            guard let base = Catalog.baseImage(id: "debian-12-arm64"), let python = Catalog.toolchain(id: "python-3") else {
                throw Failure(description: "catalog entries missing")
            }
            let mounted = try store.createProject(name: "E2E Mounted", details: "", source: .empty, baseImage: base,
                                                  toolchains: [python], binding: binding)
            try await setUp(mounted, store: store, provisioner: provisioner)

            // 2. Start, editor, and files through the mount.
            let endpoint = try await open(mounted, runtime: runtime, store: store)
            try check(try await read("/workspace/hello.txt", endpoint) == "from the iPad", "Linux reads a file from the folder")
            try Data("written later".utf8).write(to: folder.appending(path: "later.txt"))
            try check(try await read("/workspace/later.txt", endpoint) == "written later", "Linux sees a file created while it runs")

            // 3. Switch to a project stored in Runfern; the warm QEMU swaps its disk.
            let inApp = try store.createProject(name: "E2E Internal", details: "", source: .pythonStarter, baseImage: base,
                                                   toolchains: [python], binding: .appInternal())
            try await setUp(inApp, store: store, provisioner: provisioner)
            let second = try await open(inApp, runtime: runtime, store: store)
            try check(try await read("/workspace/main.py", second)?.contains("print") == true, "second project shows its own files")
            await runtime.stopActiveProject()
            try check(store.environment(for: inApp)?.state == .stopped, "second project stopped")

            // 4. Reset and removal, including the editor data of a project whose editor never opened.
            store.resetEnvironment(of: mounted)
            try check(store.environment(for: mounted)?.state == .provisioning, "reset marks the environment for setup")
            for project in [mounted, inApp] {
                sync.removeData(for: project.workspaceBindingId)
                store.remove(project)
                await IDEWebViewCache.shared.removeData(for: project.id)
            }
            try check(store.snapshot.projects.isEmpty, "projects removed without a crash")
            try check(FileManager.default.fileExists(atPath: folder.appending(path: "hello.txt").path(percentEncoded: false)),
                      "the folder on the iPad is kept")
            try? FileManager.default.removeItem(at: folder)
            step("E2E PASSED")
        } catch {
            step("E2E FAILED: \(error)")
            await runtime.stopActiveProject()
        }
    }

    private static func setUp(_ project: Project, store: ProjectStore, provisioner: Provisioner) async throws {
        let started = ContinuousClock.now
        provisioner.start(project)
        var lastStep: ProvisioningStep?
        while provisioner.isRunning(project) {
            if let current = provisioner.currentStep[project.id], current != lastStep {
                step("\(project.name): \(current.rawValue)")
                lastStep = current
            }
            try await Task.sleep(for: .seconds(2))
        }
        let environment = store.environment(for: project)
        try check(environment?.isFullyProvisioned == true,
                  "\(project.name) set up in \((ContinuousClock.now - started).components.seconds) s \(environment?.lastError ?? "")")
    }

    private static func open(_ project: Project, runtime: RuntimeCoordinator, store: ProjectStore) async throws -> IDEEndpoint {
        let started = ContinuousClock.now
        await runtime.open(project)
        guard let endpoint = runtime.endpoint, runtime.activeProjectID == project.id else {
            throw Failure(description: "\(project.name) did not start: \(runtime.lastError ?? "unknown")")
        }
        let (_, response) = try await URLSession.shared.data(from: endpoint.url)
        try check((response as? HTTPURLResponse)?.statusCode == 200,
                  "\(project.name) editor answers after \((ContinuousClock.now - started).components.seconds) s")
        return endpoint
    }

    /// Reads a guest file through openvscode-server, which serves workspace resources to the editor.
    private static func read(_ path: String, _ endpoint: IDEEndpoint) async throws -> String? {
        var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false)!
        let token = components.queryItems?.first { $0.name == "tkn" }?.value
        components.path = "/vscode-remote-resource"
        components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "tkn", value: token)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
