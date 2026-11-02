import SwiftUI

/// Pre-downloads verified Linux bases for offline setup (OFF04).
struct BaseImagesView: View {
    @Environment(ImageLibrary.self) private var images
    @Environment(Connectivity.self) private var connectivity
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(Catalog.baseImages) { image in
                    let status = images.status(of: image)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(image.displayName).font(.headline)
                            Spacer()
                            Text(image.downloadSizeBytes.formattedBytes).foregroundStyle(.secondary)
                        }
                        Text(status.title).font(.caption).foregroundStyle(.secondary)
                        if case .downloading(let fraction) = status {
                            ProgressView(value: fraction)
                        }
                        Text("Offline setup possible with: \(Catalog.toolchains(for: image).map(\.name).formatted(.list(type: .and)))")
                            .font(.caption).foregroundStyle(.secondary)
                        // Bordered, so only the button reacts, not a tap on the row's text.
                        action(for: image, status: status)
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
                if let errorMessage { StatusLabel(errorMessage, tint: .red) }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared by all projects.")
                    if !connectivity.isOnline {
                        Text("Downloading needs an internet connection.")
                    }
                }
            }
        }
        .navigationTitle("Linux Bases")
    }

    @ViewBuilder
    private func action(for image: BaseImage, status: ImageLibrary.Status) -> some View {
        switch status {
        case .downloading, .verifying:
            Button("Cancel Download", systemImage: "xmark.circle", role: .cancel) { images.cancel(image) }
        case .missing, .partial, .failed:
            Group {
                if status == .partial {
                    Button("Resume Download", systemImage: "arrow.down.circle") { startDownload(image) }
                } else {
                    Button("Download", systemImage: "arrow.down.circle") { startDownload(image) }
                }
            }
            .disabled(!connectivity.isOnline)
        case .available, .notPublished:
            EmptyView()
        }
    }

    private func startDownload(_ image: BaseImage) {
        Task {
            do {
                try await ContinuedWork.shared.run(title: String(localized: "Downloading \(image.displayName)"),
                                                   subtitle: image.downloadSizeBytes.formattedBytes) { _ in
                    try await images.ensureAvailable(image, isOnline: connectivity.isOnline)
                }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
