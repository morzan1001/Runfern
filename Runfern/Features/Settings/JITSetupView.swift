#if RUNFERN_JIT
import SwiftUI
import UIKit

/// Sets up the built-in JIT step by step (`JITSetup`). Runfern does everything it can by itself;
/// the person only answers iPadOS's prompts (VPN, Local Network, notifications) and confirms the
/// pairing in Settings with the code shown here.
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
                    StepRow(title: "Allow Runfern's VPN", detail: "iPadOS asks once.", state: setup.vpnStep)
                    StepRow(title: "Pair This iPad", detail: "Once; again only after the passcode changes.", state: setup.pairingStep)
                    if setup.pairingStep == .running {
                        pairingDetails
                    }
                    if !setup.isRunning, setup.pairingStep != .done, setup.pairing.needsLocalNetworkPermission {
                        Button("Open Runfern's Settings", systemImage: "network") {
                            openSettings()
                        }
                    }
                    StepRow(title: "Check the Connection",
                            detail: "The first time, this downloads the Developer Disk Image, which needs the internet and can take a few minutes.",
                            state: setup.checkStep)
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
                if setup.isDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", role: .confirm) { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) {
                            setup.cancel()
                            dismiss()
                        }
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
        [setup.vpnStep, setup.pairingStep, setup.checkStep].contains { state in
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
                Text("In Settings, tap Privacy & Security in the sidebar and then Developer Mode at the very bottom, or search Settings for “Developer Mode”. Tap “Pair with \(name)”, then enter the code Runfern shows here and in a notification.")
                Button("Open Settings", systemImage: "gear") { openSettings() }
                    .buttonStyle(.borderedProminent)
                Text("Tip: Keep Settings and Runfern side by side, as windows or in Stage Manager, to see the code while you type it. Stay on Wi-Fi; no internet connection is needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .pairing(let code):
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

    /// Opens Runfern's page in Settings, the only documented address. iPadOS has none for Developer
    /// Mode: on iPadOS 27 every undocumented `App-prefs:` address opens Settings › Apps as well.
    /// From there, the Settings sidebar shows Privacy & Security and the search field.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { _ = await UIApplication.shared.open(url) }
    }
}

/// One step of the setup with its state: the icon or spinner beside the title, the explanation or
/// the failure below it, aligned with the title.
private struct StepRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let state: JITSetup.StepState

    @ScaledMetric private var iconWidth: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                icon
                    .frame(width: iconWidth)
                Text(title)
            }
            Group {
                if case .failed(let message) = state {
                    Text(message)
                        .foregroundStyle(.red)
                } else {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .padding(.leading, iconWidth + 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
    }

    /// What the icon alone shows; the spinner and the failure text speak for themselves.
    private var accessibilityState: String {
        switch state {
        case .pending: String(localized: "pending")
        case .done: String(localized: "done")
        case .running, .failed: ""
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .running:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
    }
}

#Preview {
    JITSetupView()
}
#endif
