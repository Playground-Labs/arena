import SwiftUI

/// Shared tint feedback for custom buttons and menu triggers; never changes layout.
struct ArenaHoverFeedback: ViewModifier {
    var pressed = false
    var cornerRadius: CGFloat = 6
    var accent = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill((accent || colorScheme == .light ? Color.black : .white)
                        .opacity(isEnabled ? pressed ? 0.15 : hovered ? 0.08 : 0 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered && isEnabled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed && isEnabled)
    }
}

struct ArenaButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var accent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ArenaHoverFeedback(pressed: configuration.isPressed, cornerRadius: cornerRadius, accent: accent))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Custom buttons retain Tab focus and Space/Return activation on macOS.
struct ArenaKeyboardButtonStyle: PrimitiveButtonStyle {
    var cornerRadius: CGFloat = 6
    var accent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) { configuration.label }
            .buttonStyle(ArenaButtonStyle(cornerRadius: cornerRadius, accent: accent))
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.space, .return]) { _ in
                guard isEnabled else { return .ignored }
                configuration.trigger()
                return .handled
            }
    }
}
