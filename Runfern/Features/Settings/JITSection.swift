#if RUNFERN_JIT
import SwiftUI

/// JIT compilation in builds for sideloading: the setting, how the debugger is obtained, and what
/// this app session uses. The built-in method's details and actions live on their own page
/// (`BuiltInJITView`), like a Wi-Fi network's in Settings; this section only offers the setup
/// while JIT is not set up yet.
struct JITSection: View {
    @AppStorage(JITSupport.enabledKey) private var isEnabled = true
    @AppStorage(JITAcquisition.methodKey) private var storedMethod: JITMethod?
    var isIncluded = JITSupport.isIncluded
    var builtInUnavailableReason = BuiltInJIT.unavailableReason
    var canCreatePairingFile = OnDevicePairing.isSupported

    @State private var isSettingUp = false
    @State private var pairingState = PairingFile.state
    /// `BuiltInJIT.lastError`, which SwiftUI does not observe, as of the last refresh.
    @State private var lastError = BuiltInJIT.lastError

    private var isBuiltInAvailable: Bool { builtInUnavailableReason == nil }

    private var method: Binding<JITMethod> {
        Binding(get: { storedMethod ?? (isBuiltInAvailable ? .builtIn : .stikDebug) },
                set: { storedMethod = $0 })
    }

    /// A debugger such as Xcode's is attached that the chosen method does not use for JIT.
    private var hasOtherDebugger: Bool {
        JITSupport.isDebuggerAttached && !JITAcquisition.acceptsAttachedDebugger
    }

    /// With StikDebug, a debugger Runfern did not ask for is taken to be StikDebug's, which
    /// StikDebug may attach before Runfern starts. If it is Xcode's, Linux would stop at QEMU's
    /// breakpoint, so Settings says so.
    private var hasUnrequestedDebugger: Bool {
        method.wrappedValue == .stikDebug && JITSupport.isDebuggerAttached && !JITAcquisition.attachedByRunfern
            && QEMULauncher.launchedBackend == nil
    }

    var body: some View {
        if isIncluded {
            Section {
                Toggle(isOn: $isEnabled) {
                    Label("JIT Compilation", systemImage: "bolt")
                }
                // Presentations hang on this one row, which is always there: on the Section, a
                // List would attach them to every row, which then all try to present at once.
                .sheet(isPresented: $isSettingUp, onDismiss: refresh) {
                    JITSetupView()
                }
                .onAppear(perform: refresh)
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
                        if pairingState != .ready, canCreatePairingFile {
                            Button("Set Up JIT…", systemImage: "wand.and.stars") { isSettingUp = true }
                                .bold()
                        }
                        NavigationLink {
                            BuiltInJITView(canCreatePairingFile: canCreatePairingFile)
                                .onDisappear(perform: refresh)
                        } label: {
                            LabeledContent {
                                Text(builtInState)
                            } label: {
                                Label("Built-In JIT", systemImage: "cpu")
                            }
                        }
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
        }
    }

    private func refresh() {
        pairingState = PairingFile.state
        lastError = BuiltInJIT.lastError
    }

    @ViewBuilder
    private var footer: some View {
        if isEnabled, hasOtherDebugger {
            Text("Another debugger, such as Xcode's, is attached, so Linux runs interpreted. To use JIT with it, choose External Debugger and answer QEMU's breakpoint with Tools/QEMU/lldb_txm_jit.py.")
        } else if isEnabled, hasUnrequestedDebugger {
            Text("A debugger is attached that Runfern did not request. If it is Xcode's, Linux stops at QEMU's breakpoint. Start Runfern from the Home Screen, turn JIT off, or choose External Debugger and answer the breakpoint with Tools/QEMU/lldb_txm_jit.py.")
        } else if isEnabled, method.wrappedValue == .builtIn, let builtInUnavailableReason {
            Text(builtInUnavailableReason)
        } else if isEnabled, method.wrappedValue == .builtIn, pairingState != .ready {
            if canCreatePairingFile {
                Text("Tap Set Up JIT. Runfern does the rest; you only answer iPadOS's questions and confirm the pairing in Settings.")
            } else {
                Text("Built-In needs a pairing file of this iPad. Create it on a computer, as described in How Runfern Works.")
            }
        } else if QEMULauncher.launchedBackend != nil {
            Text("Takes effect after Runfern restarts.")
        }
    }

    private var builtInState: LocalizedStringKey {
        pairingState.builtInTitle(lastError: lastError)
    }

    private var status: LocalizedStringKey {
        switch QEMULauncher.launchedBackend {
        case .jit: "Active"
        case .interpreter: "Interpreter"
        case nil:
            if !isEnabled {
                "Off"
            } else if hasOtherDebugger {
                "Other Debugger Attached"
            } else if hasUnrequestedDebugger {
                "Debugger Attached"
            } else if JITSupport.isDebuggerAttached {
                "Ready"
            } else {
                switch method.wrappedValue {
                case .builtIn:
                    if !isBuiltInAvailable {
                        "Unavailable"
                    } else {
                        pairingState == .ready ? "On Next Linux Start" : "Not Set Up"
                    }
                case .stikDebug: "On Next Linux Start"
                case .externalDebugger: "No Debugger Attached"
                }
            }
        }
    }
}

extension PairingFile.State {
    /// The built-in method's state as Settings shows it, in the row and on its page.
    func builtInTitle(lastError: String?) -> LocalizedStringKey {
        switch self {
        case .ready: lastError == nil ? "Ready" : "Needs Attention"
        case .missing: "Not Set Up"
        case .unusable: "Needs Attention"
        }
    }
}

#Preview {
    NavigationStack {
        Form { JITSection(isIncluded: true, builtInUnavailableReason: nil, canCreatePairingFile: true) }
    }
}
#endif
