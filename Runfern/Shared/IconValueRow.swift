import SwiftUI

/// Form row with a title and an icon-decorated value.
/// Used instead of `LabeledContent { Label(...) }`, which renders rows with excess height inside `Form`.
struct IconValueRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Label {
                Text(value)
            } icon: {
                Image(systemName: systemImage).accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityElement(children: .combine)
    }
}
