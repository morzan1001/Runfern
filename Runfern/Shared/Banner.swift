import SwiftUI

/// Status message pinned to the bottom of a list, optionally dismissible.
struct Banner: View {
    private let text: Text
    private let systemImage: String
    private let tint: Color
    private let onDismiss: (() -> Void)?

    init(text: LocalizedStringKey, systemImage: String, tint: Color, onDismiss: (() -> Void)? = nil) {
        self.init(text: Text(text), systemImage: systemImage, tint: tint, onDismiss: onDismiss)
    }

    /// For messages that are already localized, such as an error's description. Disfavored like
    /// `Text`'s `StringProtocol` initializer, so string literals still get localized.
    @_disfavoredOverload
    init<S: StringProtocol>(text: S, systemImage: String, tint: Color, onDismiss: (() -> Void)? = nil) {
        self.init(text: Text(text), systemImage: systemImage, tint: tint, onDismiss: onDismiss)
    }

    private init(text: Text, systemImage: String, tint: Color, onDismiss: (() -> Void)?) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(alignment: .top) {
            Label {
                text
            } icon: {
                Image(systemName: systemImage)
            }
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
