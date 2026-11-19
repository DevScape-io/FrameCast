import AppKit
import ImageIO

/// Copies user images (logos, watermarks, backgrounds, frames) into Application Support and
/// serves decoded CGImages from a thread-safe cache (used by the render thread).
final class AssetStore {
    static let shared = AssetStore()
    private let cache = NSCache<NSString, CGImage>()

    func importImage(from url: URL, into folder: URL = AppPaths.assets) throws -> String {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = UUID().uuidString + "." + ext
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        return name
    }

    /// Image stored in the Assets folder.
    func asset(_ fileName: String?) -> CGImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        return image(at: AppPaths.assets.appendingPathComponent(fileName))
    }

    func image(at url: URL) -> CGImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var img: CGImage?
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
            img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        if img == nil, let ns = NSImage(contentsOf: url) {
            // Vector formats (PDF/SVG): rasterize at 4x their nominal size.
            let target = NSSize(width: ns.size.width * 4, height: ns.size.height * 4)
            var rect = CGRect(origin: .zero, size: target)
            img = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    func forget(_ url: URL) {
        cache.removeObject(forKey: url.path as NSString)
    }
}
