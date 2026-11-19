import AppKit
import AVKit

/// Quick trim after recording using AVPlayerView's built-in trimming UI, exported losslessly (passthrough).
final class TrimWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [TrimWindowController] = []

    private let url: URL
    private let playerView = AVPlayerView()

    static func present(url: URL) {
        let controller = TrimWindowController(url: url)
        openControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.beginTrim()
    }

    init(url: URL) {
        self.url = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Trim — \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .floating
        window.contentView = playerView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func beginTrim(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            guard self.playerView.canBeginTrimming else {
                if attempt < 10 { self.beginTrim(attempt: attempt + 1) }
                return
            }
            self.playerView.beginTrimming { [weak self] result in
                guard let self else { return }
                if result == .okButton { self.export() } else { self.window?.close() }
            }
        }
    }

    private func export() {
        guard let item = playerView.player?.currentItem else { return }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        guard let session = AVAssetExportSession(asset: item.asset, presetName: AVAssetExportPresetPassthrough) else { return }
        let ext = url.pathExtension
        var out = url.deletingPathExtension().appendingPathExtension("trimmed").appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = url.deletingPathExtension().appendingPathExtension("trimmed-\(n)").appendingPathExtension(ext)
            n += 1
        }
        session.outputURL = out
        session.outputFileType = ext.lowercased() == "mp4" ? .mp4 : .mov
        session.timeRange = CMTimeRange(start: start, end: end)
        window?.title = "Exporting…"
        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                if session.status == .completed {
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't export the trimmed video"
                    alert.informativeText = session.error?.localizedDescription ?? "Unknown error"
                    alert.runModal()
                }
                self?.window?.close()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        Self.openControllers.removeAll { $0 === self }
    }
}
