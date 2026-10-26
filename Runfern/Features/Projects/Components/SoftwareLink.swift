import SwiftUI

/// A form row that summarizes the selected software and opens its own page to change it, the same
/// way “Installed Software” works for an existing project.
struct SoftwareLink: View {
    let base: BaseImage?
    @Binding var selection: SoftwareSelection

    var body: some View {
        NavigationLink {
            Form {
                SoftwareSections(base: base, selection: $selection)
            }
            .navigationTitle("Software")
        } label: {
            LabeledContent("Software") {
                Text(selection.summary)
            }
        }
    }
}

extension SoftwareSelection {
    /// Tools by name and the number of extensions, for example “Python, Node.js, 3 extensions”.
    var summary: String {
        let tools = toolchains.map(\.name)
        let count = extensions.count
        let parts = tools + (count > 0 ? [String(localized: "\(count) extensions")] : [])
        return parts.isEmpty ? String(localized: "None") : parts.formatted(.list(type: .and, width: .narrow))
    }
}
