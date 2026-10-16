import AppKit
import UniformTypeIdentifiers

/// An image attached to a prompt (pasted, dropped or picked). Claude gets it as
/// a base64 `image` block in the stream-json user message; Codex gets it as a
/// file uploaded into the beam and passed with `-i`.
struct ImageAttachment: Identifiable, Hashable {
    let id: String
    let data: Data
    /// image/png or image/jpeg.
    let mediaType: String
    let thumbnail: NSImage

    var fileExtension: String { mediaType == "image/jpeg" ? "jpg" : "png" }
    var fileName: String { "\(id).\(fileExtension)" }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Claude downsizes anything larger anyway; sending it smaller saves upload
    /// time and tokens.
    static let maxEdge: CGFloat = 1568
    /// Base64 must stay under the API's 5 MB per-image limit.
    static let maxBytes = 3_500_000

    /// Decodes any image format AppKit reads, scales it to fit `maxEdge`, and
    /// re-encodes as PNG (JPEG if the PNG is too big). nil if not an image.
    static func make(from raw: Data) -> ImageAttachment? {
        guard let src = NSImage(data: raw), let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxEdge / max(w, h))
        let (tw, th) = (Int((w * scale).rounded()), Int((h * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: tw, pixelsHigh: th, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cg, size: NSSize(width: w, height: h)).draw(in: NSRect(x: 0, y: 0, width: tw, height: th))
        NSGraphicsContext.restoreGraphicsState()

        var data = rep.representation(using: .png, properties: [:]) ?? Data()
        var type = "image/png"
        if data.count > maxBytes, let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            data = jpg; type = "image/jpeg"
        }
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        let thumb = NSImage(size: NSSize(width: tw, height: th))
        thumb.addRepresentation(rep)
        return ImageAttachment(id: UUID().uuidString.lowercased(), data: data, mediaType: type, thumbnail: thumb)
    }

    /// Images on a pasteboard, or nil when the paste should be treated as text.
    /// Image files copied in Finder win; otherwise a plain-text flavor means a
    /// text paste (rich text often carries an image rendition too).
    static func fromPasteboard(_ pb: NSPasteboard) -> [ImageAttachment]? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true,
                                                         .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            let imgs = urls.compactMap { (try? Data(contentsOf: $0)).flatMap(make(from:)) }
            return imgs.isEmpty ? nil : imgs
        }
        if pb.types?.contains(.string) == true { return nil }
        for t in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                  NSPasteboard.PasteboardType(UTType.heic.identifier)] {
            if let d = pb.data(forType: t), let img = make(from: d) { return [img] }
        }
        return nil
    }

    /// Content block for a stream-json user message.
    var claudeBlock: [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
    }
}

extension AgentScripts {
    /// Writes stdin to `<dir>/<name>` in the beam (images for Codex's `-i`).
    static func writeFile(dir: String, name: String) -> String {
        "mkdir -p \(Shell.quote(dir)) && cat > \(Shell.quote(dir + "/" + name))\n"
    }
}
