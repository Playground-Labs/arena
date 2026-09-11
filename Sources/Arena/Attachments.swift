import AppKit
import Darwin
import Foundation
import ImageIO
import PDFKit

actor AttachmentFiles {
    static let shared = AttachmentFiles()
    static let maximumBytes = 20 * 1024 * 1024
    func importFile(_ source: URL, directory: URL, isBrief: Bool) throws -> Attachment {
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ArenaError.invalid("Cannot open attachment; symbolic links are not accepted.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ArenaError.invalid("Attachment must be a regular file.") }
        guard info.st_size > 0, info.st_size <= Self.maximumBytes else { throw ArenaError.invalid("Attachments must be nonempty and at most 20 MiB.") }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw ArenaError.invalid("Attachment exceeds 20 MiB.") }
        let ext = source.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "txt", "md", "markdown":
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw ArenaError.invalid("Text attachments must contain UTF-8 text.") }
            mime = ext == "txt" ? "text/plain" : "text/markdown"
        case "png", "jpg", "jpeg":
            let png = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            let jpeg = data.starts(with: [255, 216, 255])
            guard (ext == "png" ? png : jpeg),
                  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 40_000_000,
                  CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil else {
                throw ArenaError.invalid("Invalid image or image exceeds 40 megapixels.")
            }
            mime = png ? "image/png" : "image/jpeg"
        case "pdf":
            guard data.starts(with: Array("%PDF-".utf8)), let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { throw ArenaError.invalid("PDF is invalid, empty, or password protected.") }
            mime = "application/pdf"
        default: throw ArenaError.invalid("Supported attachments: UTF-8 .txt/.md, PNG, JPEG, and PDF.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let name = id + "." + ext
        let destination = directory.appendingPathComponent(name)
        do {
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return Attachment(id: id, name: source.lastPathComponent, mimeType: mime, storedName: name, byteCount: data.count, isBrief: isBrief)
    }

    private func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw ArenaError.invalid("Cannot encode image.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 12 * 1024 * 1024 else { throw ArenaError.invalid("Rendered image exceeds response capacity.") }
        return data as Data
    }

    func previewText(url: URL) throws -> (text: String, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 200_001) ?? Data()
        return (String(decoding: data.prefix(200_000), as: UTF8.self), data.count > 200_000)
    }

    func previewPDF(url: URL) throws -> sending PDFDocument {
        guard let document = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
        return document
    }

    func read(_ attachment: Attachment, url: URL, representation: String, page: Int, offset: Int, limit: Int) throws -> ArenaToolResult {
        guard ["text", "image"].contains(representation), offset >= 0, limit > 0, limit <= 50_000 else { throw ArenaError.invalid("Invalid attachment representation, offset, or limit.") }
        let data = try Data(contentsOf: url)
        var metadata = attachment.publicValue.objectValue ?? [:]
        if attachment.mimeType.hasPrefix("image/") {
            guard representation != "text" else { throw ArenaError.invalid("Use image for image attachments.") }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw ArenaError.invalid("Cannot render image.") }
            let png = try pngData(image)
            return ArenaToolResult(data: .object(metadata), images: [ToolImage(data: png, mimeType: "image/png")])
        }
        let text: String
        if attachment.mimeType == "application/pdf" {
            guard let pdf = PDFDocument(data: data), page >= 1, page <= pdf.pageCount, let pdfPage = pdf.page(at: page - 1) else { throw ArenaError.invalid("PDF page is out of range.") }
            metadata["page"] = .int(page); metadata["page_count"] = .int(pdf.pageCount)
            if representation == "image" {
                let bounds = pdfPage.bounds(for: .mediaBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw ArenaError.invalid("Invalid PDF page dimensions.") }
                let scale = min(1600 / bounds.width, 1600 / bounds.height, 2)
                let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
                guard let pageRef = pdfPage.pageRef,
                      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ArenaError.invalid("Cannot render PDF page.") }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.concatenate(pageRef.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(pageRef)
                guard let image = context.makeImage() else { throw ArenaError.invalid("Cannot render PDF page.") }
                let png = try pngData(image)
                return ArenaToolResult(data: .object(metadata), images: [ToolImage(data: png, mimeType: "image/png")])
            }
            text = pdfPage.string ?? ""
        } else {
            guard representation != "image", let decoded = String(data: data, encoding: .utf8) else { throw ArenaError.invalid("Use text for text attachments.") }
            text = decoded
        }
        let count = text.count
        guard offset <= count else { throw ArenaError.invalid("Text offset is out of range.") }
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: min(limit, count - offset))
        metadata["text"] = .string(String(text[start..<end]))
        metadata["next_offset"] = .int(offset + text[start..<end].count)
        metadata["has_more"] = .bool(end < text.endIndex)
        return ArenaToolResult(data: .object(metadata))
    }
}
