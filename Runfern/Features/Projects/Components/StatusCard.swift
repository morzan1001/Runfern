import SwiftUI

/// The one card at the top of a project: what state it is in, details, and the actions that fit.
/// Every state, including errors, uses this layout so the page always reads the same way.
struct StatusCard<Leading: View, Content: View, Actions: View>: View {
    let title: String
    var since: Date?
    @ViewBuilder let leading: Leading
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                leading
                    .font(.title2)
                    .frame(width: 28, height: 28)
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
                HStack(spacing: 12) {
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

/// The prominent action of a status card, with a visible symbol on the filled background.
struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.white)
        }
        .buttonStyle(.glassProminent)
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
