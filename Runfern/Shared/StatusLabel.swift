import SwiftUI

/// A status, warning, or error line. The symbol carries the colour; the text keeps the label colour
/// so it stays readable (A6). Use instead of `Label(…).foregroundStyle(.orange/.red/.green)`.
struct StatusLabel: View {
    private let title: Text
    private let systemImage: String
    private let tint: Color

    init(_ titleKey: LocalizedStringKey, systemImage: String = "exclamationmark.triangle.fill", tint: Color = .orange) {
        self.init(title: Text(titleKey), systemImage: systemImage, tint: tint)
    }

    /// For messages that are already localized, such as `error.localizedDescription`.
    /// Disfavored like `Text`'s `StringProtocol` initializer, so string literals still resolve to
    /// the `LocalizedStringKey` initializer above and get localized.
    @_disfavoredOverload
    init<S: StringProtocol>(_ message: S, systemImage: String = "exclamationmark.triangle.fill", tint: Color = .orange) {
        self.init(title: Text(message), systemImage: systemImage, tint: tint)
    }

    private init(title: Text, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            title
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}

extension View {
    /// A7: an action the person started failed. The system supplies OK; OK clears `message`.
    func errorAlert(_ title: LocalizedStringKey, message: Binding<String?>) -> some View {
        alert(title,
              isPresented: Binding(get: { message.wrappedValue != nil },
                                   set: { if !$0 { message.wrappedValue = nil } }),
              presenting: message.wrappedValue) { _ in
        } message: { text in
            Text(text)
        }
    }
}
