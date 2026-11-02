import SwiftUI
import UIKit

@main struct RunfernApp: App {
    @State private var store: ProjectStore
    @State private var sync: SyncCenter
    @State private var images: ImageLibrary
    @State private var connectivity: Connectivity
    @State private var catalog = CatalogStore()
    @State private var credentials = CredentialStore()
    @State private var packages: PackageLibrary
    @State private var provisioner: Provisioner
    @State private var runtime: RuntimeCoordinator

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("downloadsOnlyOnWiFi") private var downloadsOnlyOnWiFi = true

    init() {
        AppPaths.prepare()
        #if DEBUG
        if QEMUSelfTest.isRequested {
            Task.detached { await QEMUSelfTest.run() }
        }
        if EndToEndTest.isRequested {
            Task { await EndToEndTest.run() }
        }
        #endif
        // One shared adapter instance for provisioning and runtime. Builds without the embedded
        // QEMU frameworks (see Tools/QEMU) fall back to the simulated guest.
        let adapter: EmulatorAdapter = QEMULauncher.isAvailable ? QEMUEmulatorAdapter() : SimulatedEmulatorAdapter()
        let store = ProjectStore()
        let sync = SyncCenter()
        let images = ImageLibrary(offersUnpublished: adapter.isSimulated)
        let packages = PackageLibrary()
        let connectivity = Connectivity()
        // Reads the stored sync state after launch; the journals and working-copy scans run detached.
        Task { await sync.load(store.snapshot.bindings) }
        _store = State(initialValue: store)
        _sync = State(initialValue: sync)
        _images = State(initialValue: images)
        _packages = State(initialValue: packages)
        _connectivity = State(initialValue: connectivity)
        let provisioner = Provisioner(store: store, images: images, packages: packages, sync: sync,
                                      connectivity: connectivity, adapter: adapter)
        let runtime = RuntimeCoordinator(store: store, sync: sync, adapter: adapter)
        // Setup of one project ends another project's session cleanly before it needs the VM.
        provisioner.releaseVM = { await runtime.release(for: $0) }
        _provisioner = State(initialValue: provisioner)
        _runtime = State(initialValue: runtime)
    }

    var body: some Scene {
        WindowGroup {
            mainWindow
        }
        .commands {
            EditorCommands()
            AppCommands()
        }
        // Additional windows show single projects; all windows share one runtime, so one VM at most (UX05).
        WindowGroup("Project", id: ProjectWindow.id, for: UUID.self) { $projectID in
            withServices(ProjectWindow(projectID: projectID))
        }
        .onChange(of: scenePhase) { _, phase in
            // When returning, re-check access and pull in external changes for the active session (Plan 2.5).
            // The access check runs first, off the main thread, then the sync.
            guard phase == .active else { return }
            Task { await catalog.checkIfDue(isOnline: connectivity.isOnline) }
            Task {
                await store.refreshAccess()
                if let id = runtime.activeProjectID, let project = store.project(id: id), let binding = store.binding(for: project) {
                    await sync.sync(binding)
                }
            }
        }
    }

    private var mainWindow: some View {
        withServices(ProjectOverviewView())
            .onAppear { applyNetworkPolicy() }
            .onChange(of: downloadsOnlyOnWiFi) { applyNetworkPolicy() }
            // At launch and whenever the connection comes back: newly published Linux bases
            // reach the app through the signed catalog on GitHub.
            .task(id: connectivity.isOnline) { await catalog.checkIfDue(isOnline: connectivity.isOnline) }
    }

    /// Large downloads follow the global “Wi-Fi only” setting (OFF05).
    private func applyNetworkPolicy() {
        images.allowsExpensiveNetwork = !downloadsOnlyOnWiFi
        packages.allowsExpensiveNetwork = !downloadsOnlyOnWiFi
    }

    /// Shares the app-wide services with every window.
    private func withServices(_ content: some View) -> some View {
        content
            .environment(store)
            .environment(sync)
            .environment(images)
            .environment(connectivity)
            .environment(catalog)
            .environment(credentials)
            .environment(provisioner)
            .environment(runtime)
            #if RUNFERN_JIT
            // Looks up what JIT depends on off the main thread, so the first Settings open draws
            // without file and container lookups. Runs once per window; repeats only read caches.
            .task(priority: .utility) {
                // Only while unlocked, or the protected pairing file would be cached as missing.
                let warmPairing = UIApplication.shared.isProtectedDataAvailable
                await Task.detached(priority: .utility) {
                    JITInstallation.warmUp()
                    if warmPairing { _ = PairingFile.state }
                }.value
                _ = BuiltInJIT.unavailableReason   // Now quick: it reads only cached values.
            }
            #endif
    }
}
