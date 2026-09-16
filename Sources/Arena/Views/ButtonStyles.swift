import SwiftUI

/// One shape for every Arena button: radius 6, 28pt tall, 12pt medium label.
/// `plain` keeps a caller's own layout (selection tiles, navigation rows) and only adds hover feedback.
enum ArenaButtonKind { case primary, secondary, ghost, icon, plain }

/// Shared tint feedback for custom buttons and menu triggers; never changes layout.
struct ArenaHoverFeedback: ViewModifier {
    var pressed = false
    var cornerRadius: CGFloat = 6
    var kind: ArenaButtonKind = .plain
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var strength: Double {
        guard isEnabled, pressed || hovered else { return 0 }
        return pressed ? (kind == .primary ? 0.18 : 0.15) : (kind == .primary ? 0.10 : 0.08)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill((kind == .primary ? ArenaPalette.primaryLabel : colorScheme == .light ? .black : .white).opacity(strength))
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered && isEnabled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed && isEnabled)
    }
}

struct ArenaButtonStyle: ButtonStyle {
    var kind: ArenaButtonKind = .plain
    var cornerRadius: CGFloat = 6
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        chrome(configuration.label)
            .modifier(ArenaHoverFeedback(pressed: configuration.isPressed, cornerRadius: cornerRadius, kind: kind))
            .opacity(isEnabled ? 1 : 0.4)
    }

    @ViewBuilder private func chrome(_ label: Configuration.Label) -> some View {
        switch kind {
        case .primary, .secondary:
            label.font(.system(size: 12, weight: .medium))
                .foregroundStyle(kind == .primary ? ArenaPalette.primaryLabel : ArenaPalette.text)
                .padding(.horizontal, 14).frame(height: 28)
                .background(kind == .primary ? ArenaPalette.text : ArenaPalette.panel, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay { if kind == .secondary { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(ArenaPalette.divider, lineWidth: 1) } }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        case .ghost:
            label.font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).frame(height: 28)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        case .icon:
            label.foregroundStyle(ArenaPalette.secondary)
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        case .plain:
            label
        }
    }
}

/// Custom buttons retain Tab focus and Space/Return activation on macOS.
struct ArenaKeyboardButtonStyle: PrimitiveButtonStyle {
    var kind: ArenaButtonKind = .plain
    var cornerRadius: CGFloat = 6
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) { configuration.label }
            .buttonStyle(ArenaButtonStyle(kind: kind, cornerRadius: cornerRadius))
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.space, .return]) { _ in
                guard isEnabled else { return .ignored }
                configuration.trigger()
                return .handled
            }
    }
}
