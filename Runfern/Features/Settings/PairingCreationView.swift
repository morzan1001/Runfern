#if RUNFERN_JIT
import SwiftUI

/// Creates the pairing file on this iPad: Runfern appears under Developer Mode in Settings, and
/// the person confirms the pairing there with the code shown here (`OnDevicePairing`).
struct PairingCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = OnDevicePairing()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Keep this iPad on Wi-Fi. No internet connection is needed.", systemImage: "wifi")
                    Label("Tap Start, and allow Runfern to find devices on your local network.", systemImage: "1.circle")
                    Label("Open Settings › Privacy & Security › Developer Mode and tap “Pair with \(advertisedName ?? "Runfern-…")”.", systemImage: "2.circle")
                    Label("Enter the code Runfern shows here and in a notification.", systemImage: "3.circle")
                } footer: {
                    Text("Tip: Keep Settings and Runfern side by side, as windows or in Stage Manager, to see the code while you type it.")
                }
                Section {
                    status
                }
            }
            .navigationTitle("Create Pairing File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isDone {
                        Button("Cancel", role: .cancel) {
                            pairing.cancel()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isDone {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(pairing.isRunning)
        .onDisappear { pairing.cancel() }
    }

    private var isDone: Bool {
        if case .done = pairing.phase { return true }
        return false
    }

    private var advertisedName: String? {
        switch pairing.phase {
        case .advertising(let name), .pairing(let name, _): name
        default: nil
        }
    }

    @ViewBuilder
    private var status: some View {
        switch pairing.phase {
        case .idle:
            if pairing.isRunning {
                ProgressView("Preparing…")
            } else {
                Button("Start", systemImage: "play.fill") { pairing.start() }
            }
        case .advertising(let name):
            LabeledContent {
                ProgressView()
            } label: {
                Text("Waiting for “Pair with \(name)” in Settings")
            }
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
        case .done(let deviceName):
            if let deviceName {
                Label("Paired with \(deviceName). JIT is used from the next Linux start.", systemImage: "checkmark.circle.fill")
            } else {
                Label("Paired. JIT is used from the next Linux start.", systemImage: "checkmark.circle.fill")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
            Button("Try Again", systemImage: "arrow.clockwise") { pairing.start() }
        }
    }
}

#Preview {
    PairingCreationView()
}
#endif
