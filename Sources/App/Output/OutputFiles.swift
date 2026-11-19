import AppKit
import ImageIO
import UniformTypeIdentifiers

enum OutputNaming {
    static func url(folder: String, pattern: String, tokens: TokenContext, ext: String, date: Date = Date()) -> URL {
        let dir = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var base = Tokens.resolve(pattern, tokens, date: date, fileSafe: true)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.contains("  ") { base = base.replacingOccurrences(of: "  ", with: " ") }
        base = base.replacingOccurrences(of: " -  - ", with: " - ")
        if base.isEmpty { base = "FrameCast" }
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

enum ScreenshotWriter {
    static func savePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func copyToClipboard(_ image: CGImage) {
        let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([ns])
    }
}
