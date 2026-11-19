import AppKit
import ImageIO

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("FrameCast", isDirectory: true))
    }()
    static let assets: URL = ensure(support.appendingPathComponent("Assets", isDirectory: true))
    static let frames: URL = ensure(support.appendingPathComponent("Frames", isDirectory: true))
    static let profilesFile: URL = support.appendingPathComponent("profiles.json")
    static let framesFile: URL = support.appendingPathComponent("frames.json")

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
