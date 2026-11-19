import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// A user-imported device bezel image (e.g. from Apple Design Resources).
struct ImportedFrame: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var fileName: String
    /// Where the screen sits inside the image — normalized, top-left origin.
    var screenRect: CGRect
    var isLandscape: Bool
    /// Catalog id this frame represents; used for automatic selection.
    var linkedSpecID: String?
    /// Sidebar group, e.g. the subfolder the image was imported from. Nil = ungrouped.
    var group: String?
}

/// One image waiting to be imported, with the group it should land in.
struct FrameImportItem {
    let url: URL
    let group: String?
}

/// Frame artwork handed to the compositor.
struct FrameAsset {
    let image: CGImage
    let screenRect: CGRect
    let isLandscape: Bool
}

enum FrameImportError: LocalizedError {
    case unreadable
    var errorDescription: String? { "That file couldn't be read as an image." }
}

final class FrameLibrary: ObservableObject {
    @Published var frames: [ImportedFrame] { didSet { save() } }

    init() {
        if let data = try? Data(contentsOf: AppPaths.framesFile),
           let list = try? JSONDecoder().decode([ImportedFrame].self, from: data) {
            frames = list
        } else {
            frames = []
        }
    }

    private func save() {
        let snapshot = frames
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: AppPaths.framesFile, options: .atomic)
            }
        }
    }

    func url(for frame: ImportedFrame) -> URL {
        AppPaths.frames.appendingPathComponent(frame.fileName)
    }

    func frame(id: UUID) -> ImportedFrame? {
        frames.first { $0.id == id }
    }

    func image(for frame: ImportedFrame) -> CGImage? {
        AssetStore.shared.image(at: url(for: frame))
    }

    func asset(for frame: ImportedFrame) -> FrameAsset? {
        image(for: frame).map { FrameAsset(image: $0, screenRect: frame.screenRect, isLandscape: frame.isLandscape) }
    }

    /// The other-orientation sibling of a frame (same linked model), if one was imported.
    func alternate(for frame: ImportedFrame) -> ImportedFrame? {
        guard let spec = frame.linkedSpecID else { return nil }
        return frames.first { $0.id != frame.id && $0.linkedSpecID == spec && $0.isLandscape != frame.isLandscape }
    }

    /// Imported frame to use automatically for a model.
    func preferred(forSpec specID: String, landscape: Bool) -> ImportedFrame? {
        let matches = frames.filter { $0.linkedSpecID == specID }
        return matches.first { $0.isLandscape == landscape } ?? matches.first
    }

    @discardableResult
    func importFrame(from url: URL) throws -> ImportedFrame {
        let frame = try Self.prepareFrame(from: url, group: nil)
        frames.append(frame)
        return frame
    }

    /// Expands files and folders into the images to import. Images inside a subfolder of a
    /// chosen folder are grouped under that subfolder's path; images directly in the folder
    /// (and loose files) stay ungrouped.
    static func importItems(from urls: [URL]) -> [FrameImportItem] {
        let fm = FileManager.default
        var items: [FrameImportItem] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue else {
                if isImage(url) { items.append(FrameImportItem(url: url, group: nil)) }
                continue
            }
            let root = url.standardizedFileURL.pathComponents
            let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var found: [FrameImportItem] = []
            while let file = walker?.nextObject() as? URL {
                guard isImage(file) else { continue }
                let folders = file.standardizedFileURL.deletingLastPathComponent().pathComponents.dropFirst(root.count)
                found.append(FrameImportItem(url: file, group: folders.isEmpty ? nil : folders.joined(separator: " › ")))
            }
            items += found.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        }
        return items
    }

    private static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Imports many images without blocking the UI: copying and screen detection run in the
    /// background, then the frames are added in one go. `completion` runs on the main queue
    /// with the new frames and how many files couldn't be read.
    func importFrames(_ items: [FrameImportItem], completion: @escaping ([ImportedFrame], Int) -> Void) {
        guard !items.isEmpty else { completion([], 0); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var added: [ImportedFrame] = []
            var failed = 0
            for item in items {
                if let f = try? Self.prepareFrame(from: item.url, group: item.group) { added.append(f) } else { failed += 1 }
            }
            DispatchQueue.main.async {
                self.frames.append(contentsOf: added)
                completion(added, failed)
            }
        }
    }

    /// Group names in sidebar order (alphabetical), without the ungrouped bucket.
    var groups: [String] {
        Array(Set(frames.compactMap(\.group))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func removeGroup(_ group: String) {
        for f in frames where f.group == group { remove(f) }
    }

    /// Copies the image into the library and works out its screen area and model. Thread-safe;
    /// doesn't touch `frames`.
    private static func prepareFrame(from url: URL, group: String?) throws -> ImportedFrame {
        let fileName = try AssetStore.shared.importImage(from: url, into: AppPaths.frames)
        let stored = AppPaths.frames.appendingPathComponent(fileName)
        guard let image = AssetStore.shared.image(at: stored) else {
            try? FileManager.default.removeItem(at: stored)
            throw FrameImportError.unreadable
        }
        let rect = Self.detectScreenRect(in: image) ?? CGRect(x: 0.06, y: 0.05, width: 0.88, height: 0.90)
        let screenPixels = CGSize(width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height))
        return ImportedFrame(name: url.deletingPathExtension().lastPathComponent,
                             fileName: fileName,
                             screenRect: rect,
                             isLandscape: image.width > image.height,
                             linkedSpecID: DeviceCatalog.match(size: screenPixels)?.id,
                             group: group)
    }

    func redetect(_ frame: ImportedFrame) {
        guard let image = image(for: frame), let rect = Self.detectScreenRect(in: image),
              let i = frames.firstIndex(where: { $0.id == frame.id }) else { return }
        frames[i].screenRect = rect
    }

    func remove(_ frame: ImportedFrame) {
        frames.removeAll { $0.id == frame.id }
        AssetStore.shared.forget(url(for: frame))
        try? FileManager.default.removeItem(at: url(for: frame))
    }

    /// Finds the transparent screen "hole" in a bezel image by scanning out from the center.
    static func detectScreenRect(in image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 10, h > 10,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // Bitmap memory row 0 is the top of the image.
        func alpha(_ x: Int, _ y: Int) -> UInt8 { px[(y * w + x) * 4 + 3] }
        func clear(_ x: Int, _ y: Int) -> Bool { alpha(x, y) < 128 }

        let cx = w / 2, cy = h / 2
        guard alpha(cx, cy) < 40 else { return nil }

        func scanX(row y: Int) -> (Int, Int) {
            var l = cx, r = cx
            while l > 0 && clear(l - 1, y) { l -= 1 }
            while r < w - 1 && clear(r + 1, y) { r += 1 }
            return (l, r)
        }
        func scanY(col x: Int) -> (Int, Int) {
            var t = cy, b = cy
            while t > 0 && clear(x, t - 1) { t -= 1 }
            while b < h - 1 && clear(x, b + 1) { b += 1 }
            return (t, b)
        }

        // Sample several rows/columns so a camera cut-out on the center line doesn't shrink the rect.
        let (l0, r0) = scanX(row: cy)
        let cols = [cx, l0 + (r0 - l0) / 4, l0 + 3 * (r0 - l0) / 4]
        let vs = cols.map { scanY(col: $0) }
        let top = vs.map { $0.0 }.min() ?? 0, bottom = vs.map { $0.1 }.max() ?? h - 1
        let rows = [cy, top + (bottom - top) / 4, top + 3 * (bottom - top) / 4]
        let hs = rows.map { scanX(row: $0) }
        let left = hs.map { $0.0 }.min() ?? 0, right = hs.map { $0.1 }.max() ?? w - 1

        let rect = CGRect(x: CGFloat(left) / CGFloat(w), y: CGFloat(top) / CGFloat(h),
                          width: CGFloat(right - left + 1) / CGFloat(w), height: CGFloat(bottom - top + 1) / CGFloat(h))
        // A "hole" covering nearly the whole image means the image has no bezel.
        guard rect.width < 0.995 || rect.height < 0.995, rect.width > 0.2, rect.height > 0.2 else { return nil }
        return rect
    }
}
