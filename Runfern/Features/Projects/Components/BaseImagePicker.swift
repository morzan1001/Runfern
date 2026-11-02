import SwiftUI

/// Chooses a Linux base in two steps: the distribution, then its release. Form rows, so it fits
/// into any section. Offers only bases this iPad can get (`ImageLibrary.isOffered`), plus the
/// current choice, so a base that is no longer offered stays visible instead of being replaced
/// without the person noticing; the screen around the picker explains it.
struct BaseImagePicker: View {
    @Binding var selection: String
    @Environment(ImageLibrary.self) private var images
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        // Read once per pass: every lookup checks the file system.
        let families = Catalog.families(of: catalog.baseImages.filter { images.isOffered($0) || $0.id == selection })
        let current = catalog.baseImages.first { $0.id == selection }
        let family = families.first { $0.distribution == current?.distribution }
        Picker("Distribution", selection: distribution(in: families, current: current)) {
            ForEach(families) { Text($0.distribution).tag($0.distribution) }
        }
        if let family {
            if family.releases.count == 1, let only = family.releases.first {
                LabeledContent("Version", value: only.release)
            } else {
                Picker("Version", selection: $selection) {
                    ForEach(family.releases) { Text($0.release).tag($0.id) }
                }
            }
        }
    }

    /// Changing the distribution selects its first release.
    private func distribution(in families: [BaseImageFamily], current: BaseImage?) -> Binding<String> {
        Binding(get: { current?.distribution ?? "" },
                set: { name in
                    if let first = families.first(where: { $0.distribution == name })?.releases.first {
                        selection = first.id
                    }
                })
    }
}

#Preview {
    @Previewable @State var selection = Catalog.baseImages.first?.id ?? ""
    Form { BaseImagePicker(selection: $selection) }
        .environment(ImageLibrary(offersUnpublished: true))
        .environment(CatalogStore())
}
