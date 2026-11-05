import SwiftUI

/// The Linux bases this iPad can use: published in the signed catalog or already installed. They
/// download by themselves when a project needs one; here they can be fetched ahead for offline
/// setup or removed when no project uses them.
struct BaseImagesView: View {
    @Environment(ImageLibrary.self) private var images
    @Environment(CatalogStore.self) private var catalog
    @Environment(ProjectStore.self) private var store
    @Environment(Connectivity.self) private var connectivity
    @State private var downloadError: String?
    @State private var removalError: String?
    @State private var confirmingRemoval: BaseImage?

    var body: some View {
        // Read once per pass: every lookup checks the file system.
        let offered = images.offered(catalog.baseImages)
        let referenced = store.referencedImageDirectories
        Form {
            if !offered.isEmpty {
                Section {
                    ForEach(offered) { image in
                        row(for: image, status: images.status(of: image),
                            isInUse: referenced.contains(AppPaths.imageDirectoryName(image.id, version: image.catalogVersion)))
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shared by all projects. A base downloads by itself the first time a project needs it.")
                        if !connectivity.isOnline {
                            Text("Downloading needs an internet connection.")
                        }
                    }
                }
            }
        }
        .overlay {
            if offered.isEmpty {
                emptyState
            }
        }
        .navigationTitle("Linux Bases")
        .errorAlert("Couldn’t Download Linux Base", message: $downloadError)
        .errorAlert("Couldn’t Remove Linux Base", message: $removalError)
    }

    /// No base can be set up on this iPad yet (A8). Whether none is published or the catalog
    /// couldn’t be fetched isn’t known here, so the text speaks from the iPad’s point of view.
    @ViewBuilder
    private var emptyState: some View {
        if catalog.isChecking {
            ContentUnavailableView {
                ProgressView("Looking for Linux bases…")
            }
        } else {
            ContentUnavailableView {
                Label("No Linux Bases", systemImage: "shippingbox")
            } description: {
                if connectivity.isOnline {
                    Text("No Linux base is available on this iPad yet. New ones arrive with catalog updates.")
                } else {
                    Text("Runfern looks for Linux bases once this iPad is online.")
                }
            } actions: {
                if CatalogStore.updateURL != nil {
                    Button("Check for Catalog Update") {
                        Task { await catalog.checkForUpdate(isOnline: connectivity.isOnline) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connectivity.isOnline)
                }
            }
        }
    }

    private func row(for image: BaseImage, status: ImageLibrary.Status, isInUse: Bool) -> some View {
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
            if status == .available, isInUse {
                Text("Used by projects on this iPad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Bordered, so only the button reacts, not a tap on the row's text.
            action(for: image, status: status, isInUse: isInUse)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func action(for image: BaseImage, status: ImageLibrary.Status, isInUse: Bool) -> some View {
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
        case .available where !isInUse:
            Button("Remove…", systemImage: "trash", role: .destructive) { confirmingRemoval = image }
                // On the button, so on iPad the dialog points at it (A4).
                .confirmationDialog("Remove \(image.displayName)?", isPresented: removalBinding(for: image),
                                    titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { remove(image) }
                } message: {
                    // What is lost (A4): an installed base the catalog doesn't publish is gone for good.
                    if image.source == nil {
                        Text("It isn’t published for download, so it can’t be downloaded again.")
                    } else {
                        Text("It must be downloaded again before an offline setup.")
                    }
                }
        case .available, .notPublished:
            EmptyView()
        }
    }

    private func removalBinding(for image: BaseImage) -> Binding<Bool> {
        Binding(get: { confirmingRemoval?.id == image.id },
                set: { if !$0 { confirmingRemoval = nil } })
    }

    private func remove(_ image: BaseImage) {
        Task {
            do {
                try await images.remove(image)
            } catch {
                removalError = error.localizedDescription
            }
        }
    }

    private func startDownload(_ image: BaseImage) {
        Task {
            do {
                try await ContinuedWork.shared.run(title: String(localized: "Downloading \(image.displayName)"),
                                                   subtitle: image.downloadSizeBytes.formattedBytes) { _ in
                    try await images.ensureAvailable(image, isOnline: connectivity.isOnline)
                }
            } catch is CancellationError {
                // Cancelled in the system's progress UI: nothing to report.
            } catch let error as URLError where error.code == .cancelled {
                // Cancelled with Cancel Download: nothing to report.
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }
}
