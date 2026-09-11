import Foundation
import AppKit
import PDFKit

/// Explicit opt-in fixture for repeatable integration checks; never runs in normal launches.
@MainActor
func prepareSmokeFixture(store: ArenaStore, configuration: ArenaConfiguration) throws {
    guard let path = configuration.fixturePath else { return }
    let destination = URL(fileURLWithPath: path)
    let folder = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let textURL = folder.appendingPathComponent("proposal.md")
    try "# Review fixture\nPrefer bounded waits. Verification phrase: cobalt lantern.\n".write(to: textURL, atomically: true, encoding: .utf8)
    let imageURL = folder.appendingPathComponent("diagram.png")
    let image = NSImage(size: NSSize(width: 480, height: 240), flipped: false) { bounds in
        NSColor.systemIndigo.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.white]
        "ARENA 42".draw(at: NSPoint(x: 140, y: 100), withAttributes: attributes)
        return true
    }
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw ConfigurationError.message("Could not render the smoke-test image.")
    }
    try png.write(to: imageURL)
    let pdfURL = folder.appendingPathComponent("review.pdf")
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 280))
    view.string = "Arena PDF verification\nAmber compass.\nA shared outcome requires every participant."
    view.font = .systemFont(ofSize: 22)
    try view.dataWithPDF(inside: view.bounds).write(to: pdfURL)
    let files = [textURL, imageURL, pdfURL]
    let two = try store.createSession(name: "The polling question", brief: "Review bounded waiting for an agent conversation. Discuss tradeoffs as peers, then agree on a closing assessment or an impasse.", agentCount: 2, files: files)
    let three = try store.createSession(name: "Three perspectives", brief: "Review a local-first proposal as three peers.", agentCount: 3)
    let isolated = try store.createSession(name: "Separate session", brief: "Cross-session access must remain isolated.", agentCount: 2)
    let sessions = [two, three, isolated].compactMap { id in store.sessions.first { $0.id == id } }
    let object: [String: Any] = [
        "endpoint": "http://127.0.0.1:\(configuration.port)/mcp",
        "token": configuration.token,
        "sessions": sessions.map { session in
            ["id": session.id, "name": session.name,
             "invitations": session.participants.map(\.invitation),
             "attachments": session.attachments.map { ["id": $0.id, "name": $0.name] }] as [String: Any]
        },
        "files": files.map(\.path)
    ]
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
}
