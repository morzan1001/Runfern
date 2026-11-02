#if RUNFERN_JIT
import SwiftUI
import UniformTypeIdentifiers

/// JIT compilation in builds for sideloading: the setting, how the debugger is obtained, and what
/// this app session uses.
struct JITSection: View {
    @AppStorage(JITSupport.enabledKey) private var isEnabled = true
    @AppStorage(JITAcquisition.methodKey) private var storedMethod: JITMethod?
    var isIncluded = JITSupport.isIncluded
    var isBuiltInAvailable = BuiltInJIT.isAvailable

    @State private var isImporting = false
    @State private var pairingState = PairingFile.state
    @State private var message: String?

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
                        if isBuiltInAvailable {
                            Text("Built-In").tag(JITMethod.builtIn)
                        }
                        Text("StikDebug").tag(JITMethod.stikDebug)
                        Text("External Debugger").tag(JITMethod.externalDebugger)
                    } label: {
                        Label("Method", systemImage: "ladybug")
                    }
                    if method.wrappedValue == .builtIn {
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
                if let message = message ?? (method.wrappedValue == .builtIn ? BuiltInJIT.lastError : nil) {
                    Text(message)
                } else {
                    Text("Takes effect after Runfern restarts.")
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.propertyList, .data]) { result in
                do {
                    try PairingFile.importFile(at: result.get())
                    message = nil
                } catch {
                    message = error.localizedDescription
                }
                pairingState = PairingFile.state
            }
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
        Button("Import Pairing File…", systemImage: "square.and.arrow.down") { isImporting = true }
        if pairingState != .missing {
            Button("Remove Pairing File", systemImage: "trash", role: .destructive) {
                PairingFile.remove()
                pairingState = PairingFile.state
            }
        }
        Button("Reset Developer Disk Image", systemImage: "arrow.counterclockwise") {
            Task { message = await BuiltInJIT.resetDiskImage() }
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
                    switch pairingState {
                    case .ready: "On Next Linux Start"
                    case .missing: "Pairing File Missing"
                    case .unusable: "Pairing File Unusable"
                    }
                case .stikDebug: "On Next Linux Start"
                case .externalDebugger: "No Debugger Attached"
                }
            }
        }
    }
}

#Preview {
    Form { JITSection(isIncluded: true, isBuiltInAvailable: true) }
}
#endif
