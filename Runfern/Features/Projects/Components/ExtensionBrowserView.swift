import SwiftUI

/// Searches Open VSX for VS Code extensions. Without a search term it lists the most downloaded ones.
struct ExtensionBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: SoftwareSelection

    @State private var query = ""
    @State private var results: [OpenVSXClient.Summary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    ContentUnavailableView("Open VSX Not Reachable", systemImage: "wifi.exclamationmark",
                                           description: Text(errorMessage))
                } else if results.isEmpty, !isLoading {
                    ContentUnavailableView.search(text: query)
                }
                if !results.isEmpty {
                    Section(query.isEmpty ? String(localized: "Popular") : String(localized: "Results")) {
                        extensionRows
                    }
                }
            }
            .overlay { if isLoading && results.isEmpty { ProgressView() } }

            .searchable(text: $query, prompt: Text("Search Open VSX"))
            .task(id: query) { await load() }
            .navigationTitle("VS Code Extensions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
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
        // Waits briefly while typing, so not every keystroke starts a request.
        if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            results = try await OpenVSXClient().search(query)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
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

struct ExtensionIcon: View {
    let url: URL?
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "puzzlepiece.extension").font(.title2).foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size / 5))
    }
}

#Preview {
    @Previewable @State var selection = SoftwareSelection(toolchainIds: ["python-3"])
    ExtensionBrowserView(selection: $selection)
}
