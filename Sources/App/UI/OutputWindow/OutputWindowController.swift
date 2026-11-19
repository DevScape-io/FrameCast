import AppKit
import SwiftUI
import Combine

/// How the detached output window looks.
enum OutputStyle: String, CaseIterable, Identifiable {
    /// The full branded canvas: background, padding, header and footer.
    case canvas
    /// Just the framed device floating on the desktop, with no window or background.
    case frameOnly

    var id: String { rawValue }
    var label: String { self == .canvas ? "Canvas" : "Frame Only" }
    var symbol: String { self == .canvas ? "photo.artframe" : "ipad.and.iphone" }
}

/// State shared between the output window controller and its SwiftUI controls.
@MainActor
final class OutputChrome: ObservableObject {
    /// True while the customize popover is open, so the controls don't fade out under it.
    @Published var isCustomizing = false
    /// Height of the frame-only window, in points.
    @Published var frameHeight: Double = 640
    @Published var frameHeightRange: ClosedRange<Double> = 200...1200
    /// True when the strip had to go on the left of the output (no room on the right).
    @Published var stripOnLeft = false
    /// Height available to the settings pane when the strip is expanded.
    @Published var settingsHeight: Double = 560
    /// Height of the tool strip itself, reported by the view; used to keep the strip
    /// vertically centered on the output no matter what else the panel is showing.
    @Published var stripHeight: CGFloat = 0
    var setFrameHeight: (Double) -> Void = { _ in }
}

private final class OutputWindow: NSWindow {
    // Borderless windows refuse key status by default; the output needs it for shortcuts.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // Borderless windows have no close button, so ⌘W would just beep.
    override func performClose(_ sender: Any?) { close() }
}

private final class ControlsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the detached output window and the floating controls beside it.
///
/// The controls live in a separate child panel rather than inside the output window, so
/// sharing just the output window in a video call never shows them. The panel is also
/// marked `sharingType = .none`, which hides it from full-screen shares in apps that honor it.
@MainActor
final class OutputWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private let chrome = OutputChrome()

    private var window: OutputWindow?
    private var panel: ControlsPanel?
    private var host: NSHostingController<AnyView>?
    private var style: OutputStyle = .canvas
    private var shownSize = CGSize(width: 3, height: 4)

    private var cancellables = Set<AnyCancellable>()
    private var sizeObservation: NSKeyValueObservation?
    private var hoverTimer: Timer?
    private var lastHover = Date.distantPast
    private var controlsShown = true
    private var isRebuilding = false
    /// Output window frame from before the strip expanded, restored when it collapses.
    private var frameBeforeSettings: NSRect?
    private var isFitting = false

    init(model: AppModel) {
        self.model = model
        super.init()
        chrome.setFrameHeight = { [weak self] h in
            // A manual resize while the settings are open becomes the new size to keep.
            self?.frameBeforeSettings = nil
            self?.setFrameOnlyHeight(CGFloat(h))
        }

        model.settings.$outputStyle
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] newStyle in
                // @Published fires before the property changes, so hop to the next turn.
                DispatchQueue.main.async { self?.rebuild(as: newStyle) }
            }
            .store(in: &cancellables)
        chrome.$isCustomizing
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] on in DispatchQueue.main.async { self?.settingsToggled(on) } }
            .store(in: &cancellables)
        chrome.$stripHeight
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.positionPanel() } }
            .store(in: &cancellables)
        model.$alwaysOnTop
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyLevel() } }
            .store(in: &cancellables)
    }

    // MARK: Showing and hiding

    func show() {
        if window == nil { build(style: model.settings.outputStyle) }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        if let panel, panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        applyLevel()
        positionPanel()
        startHoverTracking()
    }

    func close() {
        window?.close()
    }

    private func rebuild(as newStyle: OutputStyle) {
        guard let old = window, newStyle != style else { return }
        let wasVisible = old.isVisible
        isRebuilding = true
        old.close()
        isRebuilding = false
        build(style: newStyle)
        if wasVisible { show() }
    }

    private func build(style newStyle: OutputStyle) {
        style = newStyle
        let frameOnly = newStyle == .frameOnly

        let mask: NSWindow.StyleMask = frameOnly
            ? [.borderless, .resizable, .miniaturizable]
            : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let w = OutputWindow(contentRect: NSRect(x: 0, y: 0, width: frameOnly ? 440 : 960, height: frameOnly ? 640 : 720),
                             styleMask: mask, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "FrameCast Output"
        w.delegate = self
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.minSize = NSSize(width: 160, height: 160)
        w.collectionBehavior.insert(.fullScreenAuxiliary)
        if !frameOnly {
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
        }

        let preview = PreviewNSView()
        preview.kind = frameOnly ? .deviceOnly : .canvas
        preview.flashesOnScreenshot = true
        preview.onShownSizeChange = { [weak self] size in self?.shownSizeChanged(size) }
        preview.onMagnify = { [weak self] m in self?.magnify(by: m) }
        preview.attach(model: model)

        if frameOnly {
            w.contentView = preview
        } else {
            let effect = NSVisualEffectView()
            effect.blendingMode = .behindWindow
            effect.material = .fullScreenUI
            effect.state = .active
            preview.frame = effect.bounds
            preview.autoresizingMask = [.width, .height]
            effect.addSubview(preview)
            w.contentView = effect
        }

        let name = "FrameCastOutput.\(newStyle.rawValue)"
        if !w.setFrameUsingName(name) { w.center() }
        w.setFrameAutosaveName(name)
        window = w

        buildPanel()
        updateHeightRange()
    }

    private func buildPanel() {
        let p = ControlsPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 60),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.sharingType = .none
        p.collectionBehavior.insert(.fullScreenAuxiliary)

        let root = OutputControls(chrome: chrome)
            .environmentObject(model)
            .environmentObject(model.settings)
            .environmentObject(model.profiles)
            .environmentObject(model.presenter)
        let h = NSHostingController(rootView: AnyView(root))
        h.sizingOptions = [.preferredContentSize]
        p.contentViewController = h
        sizeObservation = h.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.positionPanel() } }
        }
        host = h
        panel = p
        controlsShown = true
        p.alphaValue = 1
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        if !isRebuilding {
            frameBeforeSettings = nil
            chrome.isCustomizing = false
        }
        hoverTimer?.invalidate()
        hoverTimer = nil
        sizeObservation = nil
        if let panel {
            w.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        // Take the preview out of the window so it stops receiving frames right away.
        w.contentView = nil
        window = nil
        panel = nil
        host = nil
        if !isRebuilding { model.outputWindowDidClose() }
    }

    func windowDidResize(_ notification: Notification) {
        positionPanel()
        if let window { chrome.frameHeight = window.frame.height }
    }

    func windowDidMove(_ notification: Notification) {
        positionPanel()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateHeightRange()
        positionPanel()
    }

    // MARK: Geometry

    private func applyLevel() {
        let level: NSWindow.Level = model.alwaysOnTop ? .floating : .normal
        window?.level = level
        panel?.level = level
    }

    /// Fits the window to the shown image's aspect (device rotated, frame or canvas changed).
    private func shownSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, let window else { return }
        shownSize = size
        window.contentAspectRatio = size
        var f = window.frame
        var height = f.height
        var width = height * size.width / size.height
        if let visible = window.screen?.visibleFrame {
            // Leave room beside a wide canvas for the control strip, so it sits next to the
            // output rather than on top of it.
            let reserve: CGFloat = style == .canvas ? 150 : 0
            let k = min(1, (visible.width - reserve) / width, visible.height / height)
            width *= k
            height *= k
        }
        f.origin.x += (f.width - width) / 2
        f.origin.y += f.height - height
        f.size = CGSize(width: width, height: height)
        window.setFrame(f, display: true)
        chrome.frameHeight = height
        positionPanel()
        if style == .frameOnly {
            // The shadow follows the window's alpha; recompute it once the new shape is drawn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.window?.invalidateShadow() }
        }
    }

    private func setFrameOnlyHeight(_ height: CGFloat) {
        guard let window, shownSize.height > 0 else { return }
        let h = min(max(height, CGFloat(chrome.frameHeightRange.lowerBound)), CGFloat(chrome.frameHeightRange.upperBound))
        let w = h * shownSize.width / shownSize.height
        var f = window.frame
        f.origin.x += (f.width - w) / 2
        f.origin.y += f.height - h   // keep the top edge where it is
        f.size = CGSize(width: w, height: h)
        window.setFrame(f, display: true)
        window.invalidateShadow()
    }

    private func magnify(by amount: CGFloat) {
        guard let window else { return }
        setFrameOnlyHeight(window.frame.height * (1 + amount))
    }

    private func updateHeightRange() {
        let maxH = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 1200
        chrome.frameHeightRange = 200...Double(max(300, maxH))
    }

    /// A vertical strip just outside the right edge of the output, vertically centered.
    /// Falls back to the left edge when the screen has no room on the right, and to just
    /// inside the right edge when there's no room on either side.
    private func positionPanel() {
        guard let window, let panel, let host else { return }
        let size = host.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let gap: CGFloat = 10
        if chrome.isCustomizing { makeRoom(for: size, gap: gap) }
        let wf = window.frame
        let visible = window.screen?.visibleFrame ?? .infinite

        var onLeft = false
        var x = wf.maxX + gap
        if x + size.width > visible.maxX {
            if wf.minX - gap - size.width >= visible.minX {
                x = wf.minX - gap - size.width
                onLeft = true
            } else {
                x = wf.maxX - gap - size.width
            }
        }
        // Center the strip (not the whole panel) on the output: the panel's top edge sits
        // half a strip above the middle, and anything below the strip hangs down from there.
        let stripH = chrome.stripHeight > 0 ? chrome.stripHeight : size.height - 16
        let top = wf.midY + stripH / 2 + 8   // 8 = the panel's own padding
        var y = top - size.height
        y = min(max(y, visible.minY), visible.maxY - size.height)

        if chrome.stripOnLeft != onLeft { chrome.stripOnLeft = onLeft }
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    // MARK: Expanded settings

    /// The strip grows sideways to show the output settings. Make room for it beside the
    /// output (shrinking the output if the screen is too small), and put things back after.
    private func settingsToggled(_ on: Bool) {
        updateSettingsHeight()
        if on {
            if frameBeforeSettings == nil { frameBeforeSettings = window?.frame }
        } else if let saved = frameBeforeSettings, let window {
            frameBeforeSettings = nil
            isFitting = true
            window.setFrame(saved, display: true, animate: true)
            isFitting = false
        }
        // The strip's new size arrives after SwiftUI lays out; positionPanel runs then too.
        DispatchQueue.main.async { [weak self] in self?.positionPanel() }
    }

    private func updateSettingsHeight() {
        let visible = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        chrome.settingsHeight = Double(min(620, max(280, visible - 80)))
    }

    /// Shrinks and/or slides the output so it and a panel of `panelSize` fit side by side on screen.
    private func makeRoom(for panelSize: CGSize, gap: CGFloat) {
        guard let window, !isFitting, let visible = window.screen?.visibleFrame else { return }
        let inset: CGFloat = 8
        var f = window.frame
        let maxW = visible.width - panelSize.width - gap - inset * 2
        guard maxW > 200 else { return }
        if f.width > maxW {
            let k = maxW / f.width
            let top = f.maxY
            f.size = CGSize(width: f.width * k, height: f.height * k)
            f.origin.y = top - f.height
        }
        // Slide left only as far as needed for the panel to sit on the right.
        f.origin.x = max(visible.minX + inset, min(f.origin.x, visible.maxX - inset - panelSize.width - gap - f.width))
        guard f != window.frame else { return }
        isFitting = true
        window.setFrame(f, display: true, animate: false)
        isFitting = false
        chrome.frameHeight = f.height
    }

    // MARK: Hover

    /// Shows the controls while the pointer is over the output or the controls, and fades
    /// them out a moment after it leaves.
    private func startHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
    }

    private func updateHover() {
        guard let window, let panel else { return }
        let mouse = NSEvent.mouseLocation
        let zone = window.frame.union(panel.frame).insetBy(dx: -12, dy: -12)
        let busy = chrome.isCustomizing || model.countdown != nil || model.banner != nil
        if zone.contains(mouse) || busy { lastHover = Date() }
        let show = Date().timeIntervalSince(lastHover) < 1.2
        guard show != controlsShown else { return }
        controlsShown = show
        panel.ignoresMouseEvents = !show
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = show ? 1 : 0
        }
    }
}
