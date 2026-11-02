#if RUNFERN_JIT
import SwiftUI
import UniformTypeIdentifiers

/// JIT compilation in builds for sideloading: the setting, how the debugger is obtained, and what
/// this app session uses.
struct JITSection: View {
    @AppStorage(JITSupport.enabledKey) private var isEnabled = true
    @AppStorage(JITAcquisition.methodKey) private var storedMethod: JITMethod?
    var isIncluded = JITSupport.isIncluded
    var builtInUnavailableReason = BuiltInJIT.unavailableReason
    var canCreatePairingFile = OnDevicePairing.isSupported

    @State private var isImporting = false
    @State private var isCreatingPairingFile = false
    @State private var pairingState = PairingFile.state
    @State private var message: String?

    private var isBuiltInAvailable: Bool { builtInUnavailableReason == nil }

    private var method: Binding<JITMethod> {
        Binding(get: { storedMethod ?? (isBuiltInAvailable ? .builtIn : .stikDebug) },
                set: { storedMethod = $0 })
    }

    var body: some View {
        if isIncluded {
            Section {
                Toggle(isOn: $isEnabled) {
                    Label("JIT Compilation", systemImage: "bolt")
                }
                if isEnabled {
                    Picker(selection: method) {
                        // A choice that is no longer available stays visible, so it is never
                        // replaced without the person noticing.
                        if isBuiltInAvailable {
                            Text("Built-In").tag(JITMethod.builtIn)
                        } else if method.wrappedValue == .builtIn {
                            Text("Built-In (Unavailable)").tag(JITMethod.builtIn)
                        }
                        Text("StikDebug").tag(JITMethod.stikDebug)
                        Text("External Debugger").tag(JITMethod.externalDebugger)
                    } label: {
                        Label("Method", systemImage: "ladybug")
                    }
                    if method.wrappedValue == .builtIn, isBuiltInAvailable {
                        builtInRows
                    }
                }
                LabeledContent {
                    Text(status)
                } label: {
                    Label("Status", systemImage: "gauge.with.dots.needle.67percent")
                }
            } header: {
                Text("Performance")
            } footer: {
                footer
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.propertyList, .data]) { result in
                do {
                    try PairingFile.importFile(at: result.get())
                    message = nil
                    pairingFileChanged()
                } catch {
                    message = error.localizedDescription
                    pairingState = PairingFile.state
                }
            }
            .sheet(isPresented: $isCreatingPairingFile, onDismiss: pairingFileChanged) {
                PairingCreationView()
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let message {
            Text(message)
        } else if isEnabled, method.wrappedValue == .builtIn, let builtInUnavailableReason {
            Text(builtInUnavailableReason)
        } else if isEnabled, method.wrappedValue == .builtIn, let lastError = BuiltInJIT.lastError {
            Text(lastError)
        } else if isEnabled, method.wrappedValue == .builtIn, pairingState != .ready {
            if canCreatePairingFile {
                Text("Built-In needs a pairing file of this iPad. Create it here (iPadOS 27) or on a computer, as described in How Runfern Works.")
            } else {
                Text("Built-In needs a pairing file of this iPad. Create it on a computer, as described in How Runfern Works.")
            }
        } else if QEMULauncher.launchedBackend != nil {
            Text("Takes effect after Runfern restarts.")
        }
    }

    @ViewBuilder
    private var builtInRows: some View {
        LabeledContent {
            switch pairingState {
            case .ready: Text("Imported")
            case .missing: Text("Missing")
            case .unusable: Text("Wrong Format")
            }
        } label: {
            Label("Pairing File", systemImage: "key")
        }
        if canCreatePairingFile {
            Button("Create on This iPad…", systemImage: "ipad") {
                message = nil
                isCreatingPairingFile = true
            }
        }
        Button("Import Pairing File…", systemImage: "square.and.arrow.down") { isImporting = true }
        if pairingState != .missing {
            Button("Remove Pairing File", systemImage: "trash", role: .destructive) {
                PairingFile.remove()
                pairingFileChanged()
            }
        }
        Button("Reset Developer Disk Image", systemImage: "arrow.counterclockwise") {
            Task { message = await BuiltInJIT.resetDiskImage() }
        }
    }

    /// A new or removed pairing file makes the last failure meaningless.
    private func pairingFileChanged() {
        let previous = pairingState
        pairingState = PairingFile.state
        if pairingState != previous || pairingState == .ready {
            BuiltInJIT.clearLastError()
        }
    }

    private var status: LocalizedStringKey {
        switch QEMULauncher.launchedBackend {
        case .jit: "Active"
        case .interpreter: "Interpreter"
        case nil:
            if !isEnabled {
                "Off"
            } else if JITSupport.isDebuggerAttached {
                "Ready"
            } else {
                switch method.wrappedValue {
                case .builtIn:
                    if !isBuiltInAvailable {
                        "Unavailable"
                    } else {
                        switch pairingState {
                        case .ready: "On Next Linux Start"
                        case .missing: "Pairing File Missing"
                        case .unusable: "Pairing File Unusable"
                        }
                    }
                case .stikDebug: "On Next Linux Start"
                case .externalDebugger: "No Debugger Attached"
                }
            }
        }
    }
}

#Preview {
    Form { JITSection(isIncluded: true, builtInUnavailableReason: nil, canCreatePairingFile: true) }
}
#endif
