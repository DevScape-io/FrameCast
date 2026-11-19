import SwiftUI
import AppKit
import Combine

struct PreviewRepresentable: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.attach(model: model)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}
}

/// Shows the composited canvas and turns mouse input into presenter actions.
final class PreviewNSView: NSView {
    private weak var model: AppModel?
    private let imageLayer = CALayer()
    private var canvasLayout = CanvasLayout()
    private var trackingArea: NSTrackingArea?
    private var dragStart: CGPoint?
    private var cancellables = Set<AnyCancellable>()
    private var renderLoop: RenderLoop?
    private var previewToken: UUID?
    /// Part of the canvas the shown image covers (canvas pixels); nil = the whole canvas.
    private var crop: CGRect?
    private let flashLayer = CALayer()
    private let flashMask = CALayer()
    /// The pointer highlight, drawn here rather than in the rendered frame so it follows the
    /// mouse immediately instead of one render later.
    private let pointerLayer = CAShapeLayer()
    private var pointerLocation: CGPoint?

    /// Which render this view shows. Set before the view is added to a window.
    var kind: PreviewKind = .canvas
    /// Flash white over the image when a screenshot is taken.
    var flashesOnScreenshot = false
    /// Called when the shown image changes aspect (device rotated, frame changed…).
    var onShownSizeChange: ((CGSize) -> Void)?
    /// Trackpad pinch, used by the frame-only window to resize itself.
    var onMagnify: ((CGFloat) -> Void)?
    private var shownSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(imageLayer)
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        flashLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
        flashLayer.opacity = 0
        flashMask.contentsGravity = .resize
        flashLayer.mask = flashMask
        layer?.addSublayer(flashLayer)
        pointerLayer.fillColor = RGBAColor.yellow.withAlpha(0.35).cgColor
        pointerLayer.strokeColor = RGBAColor.yellow.withAlpha(0.7).cgColor
        pointerLayer.isHidden = true
        layer?.addSublayer(pointerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func attach(model: AppModel) {
        self.model = model
        self.renderLoop = model.renderLoop
        updatePreviewRegistration()
        model.presenter.$tool
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.window?.invalidateCursorRects(for: self)
            }
            .store(in: &cancellables)
        model.presenter.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updatePointerLayer() }
            .store(in: &cancellables)
        model.$flashToken
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.flash() }
            .store(in: &cancellables)
    }

    deinit {
        if let previewToken { renderLoop?.removePreviewHandler(previewToken) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePreviewRegistration()
    }

    /// Only views that are on screen receive frames, so a hidden preview costs nothing.
    private func updatePreviewRegistration() {
        guard let renderLoop else { return }
        if window != nil, previewToken == nil {
            previewToken = renderLoop.addPreviewHandler(kind: kind) { [weak self] frame in
                MainActor.assumeIsolated { self?.show(frame) }
            }
        } else if window == nil, let token = previewToken {
            renderLoop.removePreviewHandler(token)
            previewToken = nil
        }
    }

    private func show(_ frame: PreviewFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = frame.image
        CATransaction.commit()
        canvasLayout = frame.layout
        crop = frame.crop
        model?.updateCanvasSize(frame.layout.canvasSize)
        let size = frame.crop?.size ?? frame.layout.canvasSize
        if abs(size.width * shownSize.height - size.height * shownSize.width) > 0.5 || shownSize == .zero {
            shownSize = size
            needsLayout = true
            onShownSizeChange?(size)
        }
    }

    private func flash() {
        guard flashesOnScreenshot, let image = imageLayer.contents else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flashLayer.frame = imageRect
        flashMask.frame = flashLayer.bounds
        flashMask.contents = image   // white in the shape of the image, so transparent corners stay clear
        flashLayer.opacity = 0
        CATransaction.commit()
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.85
        anim.toValue = 0
        anim.duration = 0.35
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashLayer.add(anim, forKey: "flash")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        flashLayer.frame = imageRect
        flashMask.frame = flashLayer.bounds
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        guard let tool = model?.presenter.tool else { return }
        switch tool {
        case .pen, .highlighter, .redact: addCursorRect(bounds, cursor: .crosshair)
        case .spotlight, .zoom: addCursorRect(bounds, cursor: .crosshair)
        case .pointer: addCursorRect(bounds, cursor: .arrow)
        }
    }

    // MARK: Coordinates

    private var imageRect: CGRect {
        let c = crop?.size ?? canvasLayout.canvasSize
        guard c.width > 0, c.height > 0 else { return .zero }
        let s = min(bounds.width / c.width, bounds.height / c.height)
        let w = c.width * s, h = c.height * s
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Normalized canvas point (top-left origin), or nil when outside the canvas.
    private func canvasPoint(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let r = imageRect
        guard r.width > 0 else { return nil }
        var n = CGPoint(x: (p.x - r.minX) / r.width, y: 1 - (p.y - r.minY) / r.height)
        if clamp {
            n.x = min(1, max(0, n.x))
            n.y = min(1, max(0, n.y))
        } else if n.x < 0 || n.x > 1 || n.y < 0 || n.y > 1 {
            return nil
        }
        // Presenter state is normalized to the full canvas; map out of the crop.
        if let crop, canvasLayout.canvasSize.width > 0, canvasLayout.canvasSize.height > 0 {
            n = CGPoint(x: (crop.minX + n.x * crop.width) / canvasLayout.canvasSize.width,
                        y: (crop.minY + n.y * crop.height) / canvasLayout.canvasSize.height)
        }
        return n
    }

    /// In the frame-only window, the bezel (or anywhere with ⌘ held) drags the window.
    private func shouldDragWindow(_ event: NSEvent, at p: CGPoint?) -> Bool {
        guard kind == .deviceOnly else { return false }
        if event.modifierFlags.contains(.command) { return true }
        guard tool == .pointer, let p else { return tool == .pointer }
        let L = canvasLayout
        let pt = CGPoint(x: p.x * L.canvasSize.width, y: p.y * L.canvasSize.height)
        return !L.screenRect.contains(pt)
    }

    private var tool: PresenterTool { model?.presenter.tool ?? .pointer }

    private func mutate(_ body: (inout PresenterSnapshot) -> Void) {
        model?.renderLoop.mutatePresenter(body)
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = canvasPoint(event)
        trackPointer(event)
        mutate { $0.cursor = p }
    }

    override func mouseExited(with event: NSEvent) {
        pointerLocation = nil
        updatePointerLayer()
        mutate { $0.cursor = nil }
    }

    private func trackPointer(_ event: NSEvent) {
        pointerLocation = convert(event.locationInWindow, from: nil)
        updatePointerLayer()
    }

    /// Moves the highlight to the mouse. Sized to match what the compositor stamps into
    /// recordings (a fraction of the canvas height).
    private func updatePointerLayer() {
        let r = imageRect
        let shownHeight = crop?.height ?? canvasLayout.canvasSize.height
        let visible = tool == .pointer && (model?.presenter.highlightCursor ?? false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if visible, let p = pointerLocation, r.contains(p), shownHeight > 0 {
            let scale = r.height / shownHeight
            let radius = Compositor.pointerHighlightRadius * canvasLayout.canvasSize.height * scale
            pointerLayer.path = CGPath(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2),
                                       transform: nil)
            pointerLayer.lineWidth = max(1, 0.002 * canvasLayout.canvasSize.height * scale)
            pointerLayer.isHidden = false
        } else {
            pointerLayer.isHidden = true
        }
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if shouldDragWindow(event, at: canvasPoint(event)) {
            window?.performDrag(with: event)
            return
        }
        guard let model, let p = canvasPoint(event) else { return }
        switch tool {
        case .pen, .highlighter:
            let isHighlighter = tool == .highlighter
            let base = CGFloat(model.presenter.penWidth)
            let stroke = Stroke(points: [p], color: isHighlighter ? .yellow : model.presenter.penColor,
                                width: isHighlighter ? base * 4 : base, highlighter: isHighlighter, endedAt: nil)
            mutate { $0.strokes.append(stroke); $0.cursor = p }
        case .pointer:
            mutate { $0.clicks.append(ClickRipple(point: p, time: CACurrentMediaTime())); $0.cursor = p }
        case .redact:
            dragStart = p
            mutate { $0.pendingRedaction = CGRect(origin: p, size: .zero) }
        case .spotlight, .zoom:
            mutate { $0.cursor = p }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        trackPointer(event)
        guard let p = canvasPoint(event, clamp: true) else { return }
        switch tool {
        case .pen, .highlighter:
            mutate { s in
                if !s.strokes.isEmpty, s.strokes[s.strokes.count - 1].endedAt == nil {
                    s.strokes[s.strokes.count - 1].points.append(p)
                }
                s.cursor = p
            }
        case .redact:
            if let start = dragStart {
                let r = Self.rect(start, p)
                mutate { $0.pendingRedaction = r }
            }
        default:
            mutate { $0.cursor = p }
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .pen, .highlighter:
            let t = CACurrentMediaTime()
            mutate { s in
                if !s.strokes.isEmpty, s.strokes[s.strokes.count - 1].endedAt == nil {
                    s.strokes[s.strokes.count - 1].endedAt = t
                }
            }
        case .redact:
            if let start = dragStart, let p = canvasPoint(event, clamp: true) {
                finishRedaction(Self.rect(start, p))
            }
            dragStart = nil
            mutate { $0.pendingRedaction = nil }
        default:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard tool == .redact, let model, let p = canvasPoint(event) else {
            super.rightMouseDown(with: event)
            return
        }
        let L = canvasLayout
        let s = L.screenRect
        let pt = CGPoint(x: p.x * L.canvasSize.width, y: p.y * L.canvasSize.height)
        for r in model.profiles.selected.redactions.reversed() {
            let rect = CGRect(x: s.minX + r.rect.minX * s.width, y: s.minY + r.rect.minY * s.height,
                              width: r.rect.width * s.width, height: r.rect.height * s.height)
            if rect.contains(pt) {
                model.removeRedaction(id: r.id)
                return
            }
        }
    }

    override func magnify(with event: NSEvent) {
        if let onMagnify { onMagnify(event.magnification) } else { super.magnify(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
        switch tool {
        case .spotlight:
            mutate { $0.spotlightRadius = min(0.5, max(0.04, $0.spotlightRadius * (1 + delta))) }
        case .zoom:
            mutate { $0.zoomFactor = min(6, max(1.25, $0.zoomFactor * (1 + delta))) }
        default:
            super.scrollWheel(with: event)
        }
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Converts a normalized canvas rect into a redaction normalized to the device screen.
    private func finishRedaction(_ r: CGRect) {
        let L = canvasLayout
        guard let model, L.hasDevice, L.screenRect.width > 0 else { return }
        let canvasRect = CGRect(x: r.minX * L.canvasSize.width, y: r.minY * L.canvasSize.height,
                                width: r.width * L.canvasSize.width, height: r.height * L.canvasSize.height)
        let inter = canvasRect.intersection(L.screenRect)
        guard !inter.isNull, inter.width > 4, inter.height > 4 else { return }
        let s = L.screenRect
        model.addRedaction(CGRect(x: (inter.minX - s.minX) / s.width, y: (inter.minY - s.minY) / s.height,
                                  width: inter.width / s.width, height: inter.height / s.height))
    }
}
