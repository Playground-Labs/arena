import AppKit
import PDFKit
import SwiftUI

struct AttachmentSelection: Identifiable {
    let sessionID: String
    let attachment: Attachment
    var id: String { attachment.id }
}

struct AttachmentButton: View {
    let attachment: Attachment
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc.text")
                    .font(.system(size: 22, weight: .light)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
                         + (attachment.mimeType == "application/pdf" ? " · PDF document" : ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 16, weight: .light)).foregroundStyle(ArenaPalette.secondary)
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(ArenaPalette.sidebar, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(ArenaKeyboardButtonStyle(cornerRadius: 9)).help("Preview \(attachment.name)").accessibilityLabel("Preview attachment \(attachment.name)")
    }
}

struct AttachmentPreview: View {
    let store: ArenaStore
    let selection: AttachmentSelection
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var error: String?
    @State private var text: String?
    @State private var image: NSImage?
    @State private var document: PDFDocument?
    @State private var truncated = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selection.attachment.name).font(.headline).textSelection(.enabled)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(selection.attachment.byteCount), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url {
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(ArenaKeyboardButtonStyle(kind: .ghost))
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(ArenaKeyboardButtonStyle(kind: .secondary))
            }.padding(18)
            Divider()
            Group {
                if let error {
                    ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if let document {
                    PDFPreview(document: document)
                } else if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 850, maxHeight: 680)
                            .padding(24).accessibilityLabel(selection.attachment.name)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let text {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 15) {
                            if truncated { Label("Preview shows the first 200,000 bytes. Open the saved file for the full attachment.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                            if selection.attachment.name.lowercased().hasSuffix(".md") || selection.attachment.name.lowercased().hasSuffix(".markdown") {
                                MarkdownText(text: text)
                            } else {
                                Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(24)
                    }
                } else {
                    ProgressView("Loading attachment…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(width: 850, height: 640)
        .task { await load() }
    }

    private func load() async {
        do {
            let url = try store.attachmentURL(sessionID: selection.sessionID, attachmentID: selection.attachment.id)
            self.url = url
            if selection.attachment.mimeType == "application/pdf" {
                document = try await AttachmentFiles.shared.previewPDF(url: url)
            } else if selection.attachment.mimeType.hasPrefix("image/") {
                let result = try await AttachmentFiles.shared.read(selection.attachment, url: url, representation: "image", page: 1, offset: 0, limit: 1)
                guard let data = result.images.first?.data, let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                self.image = image
            } else {
                let result = try await AttachmentFiles.shared.previewText(url: url)
                truncated = result.truncated
                text = result.text
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}
