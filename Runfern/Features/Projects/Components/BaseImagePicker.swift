import SwiftUI

/// Chooses a Linux base in two steps: the distribution, then its release. Form rows, so it fits
/// into any section.
struct BaseImagePicker: View {
    @Binding var selection: String

    private var families: [BaseImageFamily] { Catalog.baseImageFamilies }
    private var current: BaseImage? { Catalog.baseImage(id: selection) }
    private var family: BaseImageFamily? { families.first { $0.distribution == current?.distribution } }

    var body: some View {
        Picker("Distribution", selection: distribution) {
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
    private var distribution: Binding<String> {
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
}
