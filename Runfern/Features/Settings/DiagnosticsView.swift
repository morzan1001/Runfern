import SwiftUI
import UIKit

/// Local diagnostic journal and a support report that is only created on request (SET02, SET04).
struct DiagnosticsView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(CatalogStore.self) private var catalog
    @Environment(RuntimeCoordinator.self) private var runtime

    @State private var entries: [DiagnosticEntry] = []
    @State private var reportURL: URL?
    @State private var errorMessage: String?
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                if let reportURL {
                    ShareLink(item: reportURL) { Label("Share Support Report", systemImage: "square.and.arrow.up") }
                } else {
                    Button("Create Support Report", systemImage: "doc.text.magnifyingglass", action: createReport)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            } footer: {
                Text("Contains no project names, file contents, or credentials. Nothing is sent automatically.")
            }

            Section("Events") {
                if entries.isEmpty {
                    Text("No events recorded.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text(entry.message)
                        } icon: {
                            Image(systemName: icon(for: entry.level))
                                .foregroundStyle(color(for: entry.level))
                                .accessibilityLabel(entry.level.rawValue)
                        }
                        Text("\(entry.date.formatted(date: .abbreviated, time: .standard)) · \(entry.category.rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            Button("Clear", role: .destructive) { confirmingClear = true }
                .disabled(entries.isEmpty)
        }
        .confirmationDialog("Clear Diagnostic Events?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Events", role: .destructive) {
                DiagnosticsLog.shared.clear()
                reportURL = nil
                Task { await reload() }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        entries = await Task.detached { DiagnosticsLog.shared.entries() }.value
    }

    private func createReport() {
        let context = SupportReport.Context(
            environmentStates: store.snapshot.environments.map(\.state.rawValue),
            bindingStates: store.snapshot.bindings.map { "\($0.storageMode.rawValue)/\($0.accessState.rawValue)" },
            catalogVersion: catalog.catalogVersion,
            isSimulatedRuntime: runtime.isSimulated
        )
        let report = SupportReport.make(context: context, entries: entries, deviceModel: UIDevice.current.model,
                                        systemVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        do {
            reportURL = try SupportReport.write(report)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func icon(for level: DiagnosticEntry.Level) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func color(for level: DiagnosticEntry.Level) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
