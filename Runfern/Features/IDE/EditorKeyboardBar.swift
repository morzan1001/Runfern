import Observation
import SwiftUI
import UIKit

/// Keys that the on-screen keyboard lacks for programming, shown above it while touch optimization
/// is on. With a hardware keyboard the bar stays hidden.
struct EditorKeyboardBar: View {
    let send: (EditorKey) -> Void

    private let groups: [[EditorKey]] = [
        [.escape, .tab],
        [.left, .up, .down, .right],
        EditorKey.symbols,
        [.undo, .redo, .comment],
        [.find, .quickOpen, .commands, .save],
    ]

    var body: some View {
        // Centered when everything fits, scrollable sideways in narrow windows.
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(groups, id: \.self) { group in
                        HStack(spacing: 0) {
                            ForEach(group) { key in
                                Button {
                                    send(key)
                                } label: {
                                    label(for: key)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                // The bar is capped like the system keyboard; a long press shows the key large.
                                .accessibilityShowsLargeContentViewer()
                                // Typing and cursor keys act like keyboard keys; ⌘ shortcuts are commands.
                                .accessibilityAddTraits(key.meta ? [] : .isKeyboardKey)
                            }
                        }
                        .padding(.horizontal, 4)
                        .glassEffect(.regular.interactive())
                    }
                }
                .padding(.horizontal)
            }
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.center, for: .alignment)
        // The system keyboard and its shortcut bar don't grow beyond this size either.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .font(.body.weight(.medium))
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func label(for key: EditorKey) -> some View {
        if let image = key.systemImage {
            Label(key.title, systemImage: image)
                .labelStyle(.iconOnly)
        } else {
            Text(key.title)
                .font(.body.monospaced().weight(.medium))
        }
    }
}

/// Whether the on-screen keyboard is visible. A hardware keyboard leaves at most a short shortcut
/// bar, which doesn't count.
@MainActor
@Observable
final class SoftwareKeyboard {
    private(set) var isVisible = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated { self?.isVisible = frame.height > 150 }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = false }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

#Preview {
    VStack {
        Spacer()
        EditorKeyboardBar { _ in }
    }
    .background(Color(.systemGray5))
}
