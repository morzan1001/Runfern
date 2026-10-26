import SwiftUI

/// The languages and tools a base offers, searchable. Choosing one adds it to the selection; for a
/// language with several versions, the version is chosen on the next page.
struct ToolchainCatalogView: View {
    let base: BaseImage?
    @Binding var selection: SoftwareSelection

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var families: [ToolchainFamily] {
        let all = base.map(Catalog.toolchainFamilies(for:)) ?? []
        guard !query.isEmpty else { return all }
        return all.filter { family in
            family.name.localizedStandardContains(query) || family.versions.contains { $0.summary.localizedStandardContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List(families) { family in
                if family.versions.count == 1, let only = family.versions.first {
                    Button {
                        add(only)
                    } label: {
                        row(family, detail: only.summary)
                    }
                    .foregroundStyle(.primary)
                } else {
                    NavigationLink {
                        versions(of: family)
                    } label: {
                        row(family, detail: family.versions.map(\.version).formatted(.list(type: .and, width: .narrow)))
                    }
                }
            }
            .overlay {
                if families.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, prompt: Text("Search Languages"))
            .navigationTitle("Add Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func row(_ family: ToolchainFamily, detail: String) -> some View {
        HStack(spacing: 12) {
            ToolchainIcon(family: family.id, name: family.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(family.name)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selection.selectedTool(in: family) != nil {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Added")
            }
        }
    }

    private func versions(of family: ToolchainFamily) -> some View {
        List(family.versions) { version in
            Button {
                add(version)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.version)
                        Text("\(version.summary) · \(version.estimatedSizeBytes.formattedBytes)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selection.toolchainIds.contains(version.id) {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .navigationTitle(family.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add(_ tool: ToolchainProfile) {
        selection.setTool(tool.id, selected: true)
        dismiss()
    }
}

/// A language's badge: a short label on its color. The catalog carries no logos, and SF Symbols
/// has one only for Swift.
struct ToolchainIcon: View {
    let family: String
    let name: String

    /// Colors and labels of the catalog's languages; others get a color from their name.
    private static let styles: [String: (Color, String)] = [
        "python": (.blue, "Py"), "nodejs": (.green, "JS"), "java": (.orange, "Ja"), "go": (.cyan, "Go"),
        "rust": (.brown, "Rs"), "dotnet": (.purple, ".N"), "bun": (.pink, "Bn"), "deno": (.indigo, "De"),
        "zig": (.yellow, "Zg"), "swift": (.orange, ""),
    ]

    private var style: (Color, String) {
        if let known = Self.styles[family] { return known }
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .red, .mint, .brown]
        let hash = family.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return (palette[hash % palette.count], String(name.filter(\.isLetter).prefix(2)))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(style.0.gradient)
            .frame(width: 32, height: 32)
            .overlay {
                if family == "swift" {
                    Image(systemName: "swift").foregroundStyle(.white)
                } else {
                    Text(style.1).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    @Previewable @State var selection = SoftwareSelection(toolchainIds: ["python-3"])
    ToolchainCatalogView(base: Catalog.baseImages.first, selection: $selection)
}
