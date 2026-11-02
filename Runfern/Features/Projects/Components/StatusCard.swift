import SwiftUI

/// The one card at the top of a project: what state it is in, details, and the actions that fit.
/// Every state, including errors, uses this layout so the page always reads the same way.
struct StatusCard<Leading: View, Content: View, Actions: View>: View {
    let title: String
    var since: Date?
    @ViewBuilder let leading: Leading
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Grows with the title font, so larger symbols and the spinner keep lining up with the title.
    @ScaledMetric(relativeTo: .title2) private var leadingSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                leading
                    .font(.title2)
                    .frame(width: leadingSize, height: leadingSize)
                Text(title)
                    .font(.headline)
                Spacer()
                if let since {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            content
            // Without actions, an empty row would still add spacing below the title.
            if Actions.self != EmptyView.self {
                // Stacked at accessibility sizes and in narrow windows rather than truncated. AnyLayout
                // keeps one instance of each button, so its shortcut and dialog survive the switch.
                let layout = typeSize.isAccessibilitySize || sizeClass == .compact
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    actions
                }
                .controlSize(.large)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
    }
}

extension StatusCard where Content == EmptyView {
    init(title: String, since: Date? = nil, @ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, since: since, leading: leading, content: { EmptyView() }, actions: actions)
    }
}

extension StatusCard where Actions == EmptyView {
    init(title: String, since: Date? = nil, @ViewBuilder leading: () -> Leading, @ViewBuilder content: () -> Content) {
        self.init(title: title, since: since, leading: leading, content: content, actions: { EmptyView() })
    }
}

extension StatusCard where Content == EmptyView, Actions == EmptyView {
    init(title: String, since: Date? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, since: since, leading: leading, content: { EmptyView() }, actions: { EmptyView() })
    }
}

/// The prominent action of a status card. Bordered, not glass: the card is content, not a floating control.
struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.borderedProminent)
    }
}

#Preview {
    VStack(spacing: 20) {
        StatusCard(title: "Starting Linux", since: .now) {
            ProgressView()
        }
        StatusCard(title: "Running") {
            Image(systemName: "play.circle.fill").foregroundStyle(.green)
        } actions: {
            PrimaryActionButton(title: "Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") {}
        }
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
