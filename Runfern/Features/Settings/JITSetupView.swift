#if RUNFERN_JIT
import SwiftUI
import UIKit

/// Sets up the built-in JIT step by step (`JITSetup`). Runfern does everything it can by itself;
/// the person only allows the VPN and confirms the pairing in Settings with the code shown here.
struct JITSetupView: View {
    /// Starts right away, for example to check a pairing file that was just imported.
    var startsAutomatically = false
    /// Creates a new pairing file even if one is stored.
    var forcesPairing = false

    @Environment(\.dismiss) private var dismiss
    @State private var setup = JITSetup()
    @State private var didStartAutomatically = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Runfern sets up JIT by itself. You only answer what iPadOS asks: allow Runfern's VPN, local network access, and notifications, and confirm the pairing with this iPad in Settings.")
                }
                Section {
                    StepRow(title: "Allow Runfern's VPN", detail: "iPadOS asks once.", state: setup.vpn)
                    StepRow(title: "Pair This iPad", detail: "Once; again only after the passcode changes.", state: setup.pairingStep)
                    if setup.pairingStep == .running {
                        pairingDetails
                    }
                    if !setup.isRunning, setup.pairing.needsLocalNetworkPermission {
                        Button("Open Runfern's Settings", systemImage: "network") {
                            openFirst(UIApplication.openSettingsURLString)
                        }
                    }
                    StepRow(title: "Check the Connection",
                            detail: "The first time, this downloads the Developer Disk Image, which needs the internet and can take a few minutes.",
                            state: setup.check)
                }
                Section {
                    if setup.isDone {
                        if QEMULauncher.launchedBackend == nil {
                            Label("JIT is ready. Linux uses it from its next start.", systemImage: "checkmark.seal.fill")
                        } else {
                            Label("JIT is ready. Restart Runfern to use it.", systemImage: "checkmark.seal.fill")
                        }
                    } else if !setup.isRunning {
                        if setup.canPairAgain {
                            Button("Pair Again", systemImage: "arrow.triangle.2.circlepath") {
                                setup.start(forcingPairing: true)
                            }
                        }
                        // Two buttons rather than a conditional title, which would not be localized.
                        if hasFailed {
                            Button("Try Again", systemImage: "arrow.clockwise") { setup.start() }
                        } else {
                            Button("Start", systemImage: "play.fill") { setup.start(forcingPairing: forcesPairing) }
                        }
                    }
                }
            }
            .navigationTitle("Set Up JIT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !setup.isDone {
                        Button("Cancel", role: .cancel) {
                            setup.cancel()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if setup.isDone {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(setup.isRunning)
        .onAppear {
            guard startsAutomatically, !didStartAutomatically else { return }
            didStartAutomatically = true
            setup.start(forcingPairing: forcesPairing)
        }
        .onDisappear { setup.cancel() }
    }

    private var hasFailed: Bool {
        [setup.vpn, setup.pairingStep, setup.check].contains { state in
            if case .failed = state { return true }
            return false
        }
    }

    /// What to do in Settings while Runfern waits for the pairing, and the code once it is known.
    @ViewBuilder
    private var pairingDetails: some View {
        switch setup.pairing.phase {
        case .advertising(let name):
            VStack(alignment: .leading, spacing: 12) {
                Text("In Settings, open Privacy & Security › Developer Mode and tap “Pair with \(name)”. Then enter the code Runfern shows here and in a notification.")
                Button("Open Settings", systemImage: "gear") { openSettings() }
                    .buttonStyle(.borderedProminent)
                Text("Tip: Keep Settings and Runfern side by side, as windows or in Stage Manager, to see the code while you type it. Stay on Wi-Fi; no internet connection is needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .pairing(_, let code):
            if let code {
                VStack(spacing: 8) {
                    Text("Enter this code on the iPad")
                        .font(.headline)
                    Text(code)
                        .font(.system(size: 56, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel(code.map(String.init).joined(separator: " "))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            } else {
                ProgressView("Connected…")
            }
        default:
            ProgressView("Preparing…")
        }
    }

    /// Opens Settings as close to Developer Mode as iPadOS allows: these addresses are not public,
    /// so each one that fails falls back to the next, ending with Runfern's own page in Settings.
    private func openSettings() {
        openFirst("App-prefs:Privacy&path=DEVELOPER_MODE", "App-prefs:Privacy", "App-prefs:", UIApplication.openSettingsURLString)
    }

    /// Opens the first of `candidates` that iPadOS accepts.
    private func openFirst(_ candidates: String...) {
        Task {
            for candidate in candidates {
                if let url = URL(string: candidate), await UIApplication.shared.open(url) {
                    DiagnosticsLog.record(.info, .app, "Opened Settings with \(candidate)")
                    return
                }
            }
        }
    }
}

/// One step of the setup with its state.
private struct StepRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let state: JITSetup.StepState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            icon
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

#Preview {
    JITSetupView()
}
#endif
