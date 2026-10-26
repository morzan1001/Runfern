import SwiftUI

/// Status message pinned to the bottom of a list, optionally dismissible.
struct Banner: View {
    let text: LocalizedStringKey
    let systemImage: String
    let tint: Color
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            Label(text, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            if let onDismiss {
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    // Keeps the minimum tap target of 44 pt despite the small icon.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 16)
        .background(tint.opacity(0.15))
    }
}
