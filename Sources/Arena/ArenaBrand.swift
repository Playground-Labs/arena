import AppKit
import SwiftUI

struct ArenaLogo: View {
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: ArenaBrand.mark).resizable().frame(width: size, height: size)
            .accessibilityLabel("Arena, crossed swords over a shield")
    }
}

/// One vector mark shared by the window, menu bar, and generated application icon.
@MainActor
enum ArenaBrand {
    static let mark = image(size: 100)
    static let menuIcon: NSImage = {
        let image = ArenaBrand.image(size: 18)
        image.isTemplate = true
        return image
    }()

    static func image(size: CGFloat, appIcon: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / 100, y: rect.height / 100)
            if appIcon {
                // Leave breathing room around the tile at Dock sizes.
                context.translateBy(x: 6.25, y: 6.25)
                context.scaleBy(x: 0.875, y: 0.875)
                NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 92, height: 92), xRadius: 21, yRadius: 21).fill()
                context.translateBy(x: 12, y: 12)
                context.scaleBy(x: 0.76, y: 0.76)
            }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let shield = NSBezierPath()
            shield.move(to: NSPoint(x: 50, y: 5))
            shield.line(to: NSPoint(x: 91, y: 20))
            shield.curve(to: NSPoint(x: 50, y: 96), controlPoint1: NSPoint(x: 89, y: 59), controlPoint2: NSPoint(x: 77, y: 80))
            shield.curve(to: NSPoint(x: 9, y: 20), controlPoint1: NSPoint(x: 23, y: 80), controlPoint2: NSPoint(x: 11, y: 59))
            shield.close()
            NSColor(srgbRed: 242 / 255, green: 117 / 255, blue: 15 / 255, alpha: 1).setFill()
            shield.fill()

            // Cut out both swords so the mark stays legible in either appearance.
            context.setBlendMode(.destinationOut)
            NSColor.black.setFill()
            let points: [(CGFloat, CGFloat)] = [(22, 20), (34, 24), (62, 54), (68, 48), (74, 54), (68, 60), (79, 72), (73, 78), (62, 66), (56, 72), (50, 66), (56, 60), (27, 30)]
            for mirrored in [false, true] {
                let sword = NSBezierPath()
                for (index, point) in points.enumerated() {
                    let x = mirrored ? 100 - point.0 : point.0
                    let point = NSPoint(x: 50 + (x - 50) * 0.82, y: 50 + (point.1 - 50) * 0.82)
                    if index == 0 { sword.move(to: point) } else { sword.line(to: point) }
                }
                sword.close()
                sword.fill()
            }
            context.endTransparencyLayer()
            return true
        }
    }
}
