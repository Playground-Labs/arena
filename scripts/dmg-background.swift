// Draws the disk image background: an arrow from the app slot to the Applications slot.
// Usage: swift scripts/dmg-background.swift <output.png>
// Rendered at 2x with 144 dpi metadata so Finder shows it crisp on Retina displays.
// Icon slots in release.yml must match: app at (180, 190), Applications at (480, 190), window 660x400.
import AppKit

let output = CommandLine.arguments[1]
let size = NSSize(width: 660, height: 400)
let scale: CGFloat = 2
let orange = NSColor(srgbRed: 242 / 255, green: 117 / 255, blue: 15 / 255, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

// Arrow between the two icon slots; y is measured from the bottom here.
let y: CGFloat = 400 - 190
let arrow = NSBezierPath()
arrow.lineWidth = 6
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 270, y: y))
arrow.line(to: NSPoint(x: 390, y: y))
arrow.move(to: NSPoint(x: 366, y: y + 22))
arrow.line(to: NSPoint(x: 390, y: y))
arrow.line(to: NSPoint(x: 366, y: y - 22))
orange.setStroke()
arrow.stroke()

let caption = NSAttributedString(string: "Drag Arena to Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)
])
let captionSize = caption.size()
caption.draw(at: NSPoint(x: (size.width - captionSize.width) / 2, y: 78))

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
