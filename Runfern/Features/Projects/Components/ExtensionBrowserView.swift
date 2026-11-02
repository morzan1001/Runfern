import SwiftUI

/// Searches Open VSX for VS Code extensions, pushed onto the host's navigation stack. Without a
/// search term it lists the most downloaded ones.
struct ExtensionBrowserView: View {
    @Binding var selection: SoftwareSelection

    @State private var query = ""
    @State private var results: [OpenVSXClient.Summary] = []
    /// Starts true: the first frame shows a spinner, not "No Results".
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Bumped by Try Again, so the same query loads again.
    @State private var attempt = 0

    var body: some View {
        List {
            if !results.isEmpty {
                Section(query.isEmpty ? String(localized: "Popular") : String(localized: "Results")) {
                    extensionRows
                }
            }
        }
        .overlay {
            if results.isEmpty {
                if let errorMessage {
                    ContentUnavailableView {
                        Label("Open VSX Not Reachable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") { attempt += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                } else if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, prompt: Text("Search Open VSX"))
        // Extension names and identifiers, not words.
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .task(id: "\(attempt)|\(query)") { await load() }
        .navigationTitle("VS Code Extensions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var extensionRows: some View {
        ForEach(results) { item in
            NavigationLink {
                ExtensionDetailView(id: item.id, selection: $selection)
            } label: {
                ExtensionRow(item: item, isAdded: selection.extensions.contains(item.id))
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        // A newer load has taken over; it sets the flag itself.
        defer { if !Task.isCancelled { isLoading = false } }
        // Waits briefly while typing, so not every keystroke starts a request.
        if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
        guard !Task.isCancelled else { return }
        do {
            results = try await OpenVSXClient().search(query)
        } catch {
            // A cancelled request throws URLError.cancelled, not CancellationError.
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
        }
    }
}

/// One extension: icon, name, publisher, popularity, and a short description.
struct ExtensionRow: View {
    let item: OpenVSXClient.Summary
    let isAdded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ExtensionIcon(url: item.files?.icon)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.headline).lineLimit(1)
                    if isAdded {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .accessibilityLabel("Added")
                    }
                }
                Text(byline).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if let description = item.description {
                    Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var byline: String {
        var parts = [item.namespace]
        if let downloads = item.downloadCount {
            parts.append(String(localized: "\(downloads.formatted(.number.notation(.compactName))) downloads"))
        }
        return parts.joined(separator: " · ")
    }
}

/// An extension's icon. It grows with Dynamic Type and is decorative: the name beside it is read.
struct ExtensionIcon: View {
    let url: URL?
    var size: CGFloat = 40

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "puzzlepiece.extension").font(.title2).foregroundStyle(.secondary)
        }
        .frame(width: size * scale, height: size * scale)
        .clipShape(.rect(cornerRadius: size * scale / 5))
        .accessibilityHidden(true)
    }
}

#Preview {
    @Previewable @State var selection = SoftwareSelection(toolchainIds: ["python-3"])
    NavigationStack {
        ExtensionBrowserView(selection: $selection)
    }
}
