#if RUNFERN_JIT
import SwiftUI
import UniformTypeIdentifiers

/// The built-in JIT's details and actions, opened from Settings › Performance: its state, checking
/// it, creating or importing a pairing file, and, at the end, removing it.
struct BuiltInJITView: View {
    var canCreatePairingFile = OnDevicePairing.isSupported

    @State private var pairingState = PairingFile.state
    /// `BuiltInJIT.lastError`, which SwiftUI does not observe, as of the last refresh.
    @State private var lastError = BuiltInJIT.lastError
    @State private var diskImageMessage: String?
    @State private var setup: SetupRequest?
    @State private var isImporting = false
    @State private var isConfirmingRemoval = false
    @State private var isResettingDiskImage = false
    @State private var message: String?

    /// An open `JITSetupView`.
    private struct SetupRequest: Identifiable {
        let id = UUID()
        /// Runs at once, to check a pairing file that is already there.
        var startsAutomatically = false
        /// Creates a new pairing file although one is stored.
        var forcesPairing = false
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(pairingState.builtInTitle(lastError: lastError))
                }
                LabeledContent("Pairing File") {
                    switch pairingState {
                    case .ready: Text("Ready")
                    case .missing: Text("Missing")
                    case .unusable: Text("Wrong Format")
                    }
                }
            } footer: {
                if let problem = message ?? lastError {
                    Text(problem)
                } else {
                    Text("The pairing file connects Runfern with this iPad’s developer services. Create a new one after changing or removing the iPad’s passcode.")
                }
            }

            Section {
                if pairingState == .ready {
                    Button("Check JIT", systemImage: "checkmark.shield") {
                        present(SetupRequest(startsAutomatically: true))
                    }
                    if canCreatePairingFile {
                        Button("Pair Again…", systemImage: "arrow.triangle.2.circlepath") {
                            present(SetupRequest(forcesPairing: true))
                        }
                    }
                } else if canCreatePairingFile {
                    Button("Set Up JIT…", systemImage: "wand.and.stars") {
                        present(SetupRequest())
                    }
                }
                Button("Import Pairing File…", systemImage: "square.and.arrow.down") {
                    message = nil
                    isImporting = true
                }
            } footer: {
                Text("A pairing file created on a computer, for example with Tools/JIT/create-pairing-file.sh, can be imported instead.")
            }

            Section {
                Button("Reset Developer Disk Image", systemImage: "arrow.counterclockwise") {
                    resetDiskImage()
                }
                .disabled(isResettingDiskImage)
            } footer: {
                if let diskImageMessage {
                    Text(diskImageMessage)
                } else {
                    Text("Runfern downloads it again at the next check or Linux start.")
                }
            }

            if pairingState != .missing {
                Section {
                    Button("Remove Pairing File", systemImage: "trash", role: .destructive) {
                        isConfirmingRemoval = true
                    }
                    // On the button, so that on iPad the dialog points at it.
                    .confirmationDialog("Remove Pairing File?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
                        Button("Remove Pairing File", role: .destructive) {
                            PairingFile.remove()
                            BuiltInJIT.clearLastError()
                            refresh()
                        }
                    } message: {
                        Text("Built-In JIT stops working until you set it up again.")
                    }
                }
            }
        }
        .navigationTitle("Built-In JIT")
        .onAppear(perform: refresh)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.propertyList, .data]) { result in
            do {
                try PairingFile.importFile(at: result.get())
                BuiltInJIT.clearLastError()
                refresh()
                // Check the imported file right away, once the file picker has gone.
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    setup = SetupRequest(startsAutomatically: true)
                }
            } catch {
                message = error.localizedDescription
                refresh()
            }
        }
        // The setup keeps its own result in `BuiltInJIT.lastError`, so closing it only refreshes.
        .sheet(item: $setup, onDismiss: refresh) { request in
            JITSetupView(startsAutomatically: request.startsAutomatically, forcesPairing: request.forcesPairing)
        }
    }

    private func present(_ request: SetupRequest) {
        message = nil
        setup = request
    }

    private func refresh() {
        pairingState = PairingFile.state
        lastError = BuiltInJIT.lastError
    }

    private func resetDiskImage() {
        isResettingDiskImage = true
        diskImageMessage = nil
        Task {
            diskImageMessage = await BuiltInJIT.resetDiskImage() ?? String(localized: "Developer Disk Image removed.")
            isResettingDiskImage = false
        }
    }
}

#Preview {
    NavigationStack {
        BuiltInJITView(canCreatePairingFile: true)
    }
}
#endif
