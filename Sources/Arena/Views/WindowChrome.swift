import AppKit
import SwiftUI

// Paper's flat surfaces, with no wallpaper tint or floating sidebar material.
enum ArenaPalette {
    static let sidebar = surface(light: 0xF0F0F0, dark: 0x2D2D2D)
    static let canvas = surface(light: 0xF5F5F5, dark: 0x1E1E1E)
    static let panel = surface(light: 0xFFFFFF, dark: 0x242424)
    static let toolbar = surface(light: 0xECECEC, dark: 0x303030)
    static let divider = surface(light: 0xD8D8D8, dark: 0x404040)
    static let bubbleBorder = surface(light: 0xE3E3E3, dark: 0x424242)
    static let text = surface(light: 0x000000, dark: 0xF3F3F3)
    static let secondary = surface(light: 0x686868, dark: 0xB0B0B0)
    static let selection = surface(light: 0x006BDF, dark: 0x075CB8)
    static let badge = surface(light: 0xE5E5E5, dark: 0x414141)
    static let statusNeutralFill = surface(light: 0xDADADA, dark: 0x484848)
    static let statusNeutralText = surface(light: 0x4A4A4A, dark: 0xE2E2E2)
    static let statusActiveFill = surface(light: 0xFFE3BF, dark: 0x67431C)
    static let statusConsensusFill = surface(light: 0xD8EFDE, dark: 0x315C3D)
    static let statusImpasseFill = surface(light: 0xEAD8F5, dark: 0x553664)
    static let consensus = surface(light: 0x28763B, dark: 0x96DEA5)
    static let consensusFill = surface(light: 0xE7F0E9, dark: 0x26362B)
    static let consensusBorder = surface(light: 0xC6DDCC, dark: 0x42674D)
    static let fighterOne = surface(light: 0x925014, dark: 0xF2B46C)
    static let fighterOneFill = surface(light: 0xF5EADC, dark: 0x403323)
    static let fighterTwo = surface(light: 0x784094, dark: 0xD2A4EB)
    static let fighterTwoFill = surface(light: 0xEEE5F3, dark: 0x382D41)

    private static func surface(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

/// Empty header space keeps native window dragging and double-click behavior.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
                if action == "Minimize" { window?.miniaturize(nil) }
                else if action != "None" { window?.zoom(nil) }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// Keep real AppKit window buttons, centered in Paper's 44-point title bar.
struct WindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) {}

    final class ControlsView: NSView {
        private let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        init() {
            super.init(frame: .zero)
            for (type, action) in zip(types, [#selector(closeWindow), #selector(minimizeWindow), #selector(zoomWindow)]) {
                if let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable]) {
                    button.target = self
                    button.action = action
                    addSubview(button)
                }
            }
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for type in types { window?.standardWindowButton(type)?.isHidden = true }
        }
        override func layout() {
            super.layout()
            for (index, button) in subviews.enumerated() {
                button.setFrameOrigin(NSPoint(x: CGFloat(index) * 20 + 6 - button.frame.width / 2,
                                              y: (bounds.height - button.frame.height) / 2))
            }
        }
        @objc private func closeWindow() { window?.performClose(nil) }
        @objc private func minimizeWindow() { window?.miniaturize(nil) }
        @objc private func zoomWindow() {
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true { window?.zoom(nil) }
            else { window?.toggleFullScreen(nil) }
        }
    }
}

/// A regular AppKit split view keeps Paper's flat dividers and stable side widths.
/// Its hosted content remains SwiftUI; AppKit owns resizing and divider dragging.
struct ArenaColumns: NSViewRepresentable {
    var sidebar: AnyView
    var content: AnyView
    var details: AnyView?
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> ColumnsView { ColumnsView() }
    func updateNSView(_ view: ColumnsView, context: Context) {
        view.left.rootView = AnyView(sidebar.environment(\.colorScheme, colorScheme).font(.system(size: 13)).foregroundStyle(ArenaPalette.text).tint(.orange))
        view.center.rootView = AnyView(content.environment(\.colorScheme, colorScheme).font(.system(size: 13)).foregroundStyle(ArenaPalette.text).tint(.orange))
        view.right.rootView = AnyView((details ?? AnyView(EmptyView())).environment(\.colorScheme, colorScheme).font(.system(size: 13)).foregroundStyle(ArenaPalette.text).tint(.orange))
        view.showsDetails = details != nil
        view.needsDisplay = true
    }

    final class ColumnsView: NSSplitView, NSSplitViewDelegate {
        let left = NSHostingView(rootView: AnyView(EmptyView()))
        let center = NSHostingView(rootView: AnyView(EmptyView()))
        let right = NSHostingView(rootView: AnyView(EmptyView()))
        private var leftWidth: CGFloat = 215
        private var rightWidth: CGFloat = 299
        private var arranging = false
        var showsDetails = false {
            didSet {
                guard showsDetails != oldValue else { return }
                if showsDetails { addArrangedSubview(right) } else { right.removeFromSuperview() }
                adjustSubviews()
            }
        }
        override var dividerColor: NSColor { NSColor(ArenaPalette.divider) }

        init() {
            super.init(frame: .zero)
            isVertical = true
            dividerStyle = .thin
            delegate = self
            addArrangedSubview(left)
            addArrangedSubview(center)
        }
        required init?(coder: NSCoder) { nil }

        override func resizeSubviews(withOldSize oldSize: NSSize) { adjustSubviews() }
        override func adjustSubviews() {
            guard bounds.width > 0 else { return }
            arranging = true
            defer { arranging = false }
            let seams = dividerThickness * (showsDetails ? 2 : 1)
            let rightSize = showsDetails ? min(rightWidth, max(265, bounds.width - leftWidth - 360 - seams)) : 0
            let leftSize = min(leftWidth, max(200, bounds.width - rightSize - 360 - seams))
            left.frame = NSRect(x: 0, y: 0, width: leftSize, height: bounds.height)
            center.frame = NSRect(x: leftSize + dividerThickness, y: 0,
                                  width: max(0, bounds.width - leftSize - rightSize - seams), height: bounds.height)
            if showsDetails { right.frame = NSRect(x: bounds.width - rightSize, y: 0, width: rightSize, height: bounds.height) }
        }
        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !arranging, left.frame.width >= 200, center.frame.width >= 360 else { return }
            leftWidth = left.frame.width
            if showsDetails, right.frame.width >= 265 { rightWidth = right.frame.width }
        }
        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            dividerIndex == 0 ? 200 : max(left.frame.maxX + dividerThickness + 360, bounds.width - 380 - dividerThickness)
        }
        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            dividerIndex == 0 ? min(300, bounds.width - 360 - (showsDetails ? right.frame.width : 0) - dividerThickness * (showsDetails ? 2 : 1)) : bounds.width - 265 - dividerThickness
        }
    }
}

extension Date {
    func arenaRelativeTime(to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(self)))
        if seconds < 60 { return "Now" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        if seconds < 172_800 { return "Yesterday" }
        return "\(seconds / 86_400)d"
    }
}
