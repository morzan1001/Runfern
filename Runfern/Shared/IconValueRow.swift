import SwiftUI

/// Form row with a title and an icon-decorated value.
/// Used instead of `LabeledContent { Label(...) }`, which renders rows with excess height inside `Form`.
/// Stacks at accessibility text sizes like a Form value row; long values truncate in the middle so
/// the distinguishing end of a file name stays visible.
struct IconValueRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
        layout {
            Text(title)
            if !stacked { Spacer() }
            Label {
                Text(value)
                    .lineLimit(stacked ? nil : 1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: systemImage).accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityElement(children: .combine)
    }
}
