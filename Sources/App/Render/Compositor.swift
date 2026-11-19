import AppKit
import Accelerate
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Render inputs

enum FrameSource {
    case none
    case procedural(FrameColor)
    case image(primary: FrameAsset, alternate: FrameAsset?)
}

struct RenderConfig {
    var profile = OverlayProfile()
    var spec: DeviceSpec = DeviceCatalog.genericIPad
    var frame: FrameSource = .procedural(.spaceBlack)
    var tokens = TokenContext()
    var canvasPreset: CanvasPreset = .auto
    var maxAutoSide: CGFloat = 3840
    var overlaysInRecordings = true
    var overlaysInScreenshots = true
    var overlaysInVirtualCamera = true
    var annotationFade: Double = 0
}

struct DeviceInput {
    let pixelBuffer: CVPixelBuffer
    let image: CGImage
    var size: CGSize { CGSize(width: image.width, height: image.height) }
}

/// Where things ended up on the canvas (top-left origin, canvas pixels).
struct CanvasLayout: Equatable {
    var canvasSize: CGSize = .zero
    var deviceRect: CGRect = .zero
    var screenRect: CGRect = .zero
    var headerRect: CGRect?
    var footerRect: CGRect?
    var webcamRect: CGRect?
    var nameplateRect: CGRect?
    var hasDevice = false
}

extension CanvasLayout {
    /// This layout as seen through a crop of the canvas that was scaled to `outputSize`.
    func cropped(to crop: CGRect, outputSize: CGSize) -> CanvasLayout {
        let k = outputSize.width / crop.width
        func map(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - crop.minX) * k, y: (r.minY - crop.minY) * k, width: r.width * k, height: r.height * k)
        }
        var L = self
        L.canvasSize = outputSize
        L.deviceRect = map(deviceRect)
        L.screenRect = map(screenRect)
        L.headerRect = nil
        L.footerRect = nil
        return L
    }
}

struct FrameGeometry {
    var bounds: CGSize
    var screen: CGRect
    var screenCorner: CGFloat
    var bodyCorner: CGFloat
    var asset: FrameAsset?
    var rotateAsset: Bool
}

/// Measures how rounded the screen opening of an imported bezel image is.
enum FrameHoleCorner {
    private static let lock = NSLock()
    private static var cache: [ObjectIdentifier: (image: CGImage, screenRect: CGRect, radius: CGFloat)] = [:]

    /// Corner radius of the opening, in image pixels.
    static func radius(for asset: FrameAsset) -> CGFloat {
        let key = ObjectIdentifier(asset.image)
        lock.lock()
        if let hit = cache[key], hit.screenRect == asset.screenRect {
            lock.unlock()
            return hit.radius
        }
        lock.unlock()
        let r = measure(asset.image, screenRect: asset.screenRect)
        lock.lock()
        if cache.count > 16 { cache.removeAll() }
        cache[key] = (asset.image, asset.screenRect, r)   // holding the image keeps the key valid
        lock.unlock()
        return r
    }

    /// Walks diagonally in from each corner of the screen rect until it reaches the transparent
    /// opening (past the bezel). For a rounded corner of radius r that takes r·(1 − 1/√2) pixels.
    private static func measure(_ image: CGImage, screenRect: CGRect) -> CGFloat {
        let w = image.width, h = image.height
        guard w > 10, h > 10,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        func opaque(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < w && y < h && px[(y * w + x) * 4 + 3] >= 128
        }
        let x0 = Int((screenRect.minX * CGFloat(w)).rounded()), x1 = Int((screenRect.maxX * CGFloat(w)).rounded()) - 1
        let y0 = Int((screenRect.minY * CGFloat(h)).rounded()), y1 = Int((screenRect.maxY * CGFloat(h)).rounded()) - 1
        let limit = min(x1 - x0, y1 - y0) / 2
        guard limit > 2 else { return 0 }
        var steps: [Int] = []
        for (cx, cy, dx, dy) in [(x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)] {
            // On thin bezels the rect's corner lies outside the device altogether, so the walk
            // crosses empty space first, then the bezel, then reaches the opening.
            var t = 0
            while t < limit, !opaque(cx + dx * t, cy + dy * t) { t += 1 }
            guard t < limit else { continue }   // never met the bezel: a square opening
            while t < limit, opaque(cx + dx * t, cy + dy * t) { t += 1 }
            if t < limit { steps.append(t) }
        }
        guard let t = steps.min(), t > 1 else { return 0 }
        // Slightly tighter than measured so the content tucks under the bezel edge rather
        // than leaving a sliver of background showing.
        let r = CGFloat(t) / (1 - 1 / 2.0.squareRoot()) * 0.92
        return min(r, CGFloat(limit))
    }
}

// MARK: - Drawing helpers

/// Draws an image upright in a context whose CTM has been flipped to a top-left origin.
func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
}

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    let r = max(0, min(radius, rect.width / 2 - 0.01, rect.height / 2 - 0.01))
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

private func attributed(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: RGBAColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: max(1, size), weight: weight),
        .foregroundColor: color.nsColor,
    ])
}

// MARK: - Compositor

/// Draws one canvas: background → framed device (content, redactions, status bar) →
/// overlays (watermark, header, footer) → presenter layer. Used only on the render queue.
final class Compositor {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var rotatedCache: [ObjectIdentifier: (source: CGImage, rotated: CGImage)] = [:]
    private var statusColor = RGBAColor.white
    private var statusColorAge = 1_000
    private var frameCounter = 0
    /// Latest presenter webcam frame. Set by the render loop on the render queue.
    var webcamImage: CGImage?

    /// Everything behind the screen content that only changes with settings: the background and
    /// the device body with its shadow. Drawing these takes far longer than a frame lasts (the
    /// shadow alone is ~25 ms at device resolution), so they are drawn once and copied in.
    private struct BackdropKey: Equatable {
        enum Frame: Equatable { case none, procedural(FrameColor), image }
        var size: CGSize
        var background: BackgroundSettings
        var frame: Frame
        var body: CGRect
        var screen: CGRect
        var bodyCorner: CGFloat
        var screenCorner: CGFloat
        var spec: DeviceSpec
        var shadow: Bool
    }
    /// The source images are held so a cached backdrop is only reused for the same ones.
    private var backdrops: [(key: BackdropKey, backgroundImage: CGImage?, frameImage: CGImage?, image: CGImage)] = []
    /// The current device frame, resampled to the sizes it is being drawn at.
    private var scaledScreens: [(buffer: CVPixelBuffer, crop: CGRect, width: Int, height: Int, image: CGImage)] = []

    // MARK: Geometry (pure — safe from any thread)

    static func geometry(content c: CGSize, config: RenderConfig) -> FrameGeometry {
        let spec = config.spec
        let landscape = c.width > c.height
        let sw = min(c.width, c.height)
        switch config.frame {
        case .none:
            let corner = spec.screenCornerRatio * sw
            return FrameGeometry(bounds: c, screen: CGRect(origin: .zero, size: c),
                                 screenCorner: corner, bodyCorner: corner, asset: nil, rotateAsset: false)
        case .procedural:
            let side = spec.sideBezelRatio * sw, end = spec.endBezelRatio * sw
            let h = landscape ? end : side
            let v = landscape ? side : end
            return FrameGeometry(bounds: CGSize(width: c.width + 2 * h, height: c.height + 2 * v),
                                 screen: CGRect(x: h, y: v, width: c.width, height: c.height),
                                 screenCorner: spec.hasHomeButton ? 0 : spec.screenCornerRatio * sw,
                                 bodyCorner: spec.bodyCornerRatio * sw,
                                 asset: nil, rotateAsset: false)
        case .image(let primary, let alternate):
            var asset = primary
            if primary.isLandscape != landscape, let alternate, alternate.isLandscape == landscape { asset = alternate }
            let rotate = asset.isLandscape != landscape
            var bounds = CGSize(width: asset.image.width, height: asset.image.height)
            var r = asset.screenRect
            if rotate {
                // 90° counter-clockwise: top edge → left edge.
                r = CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
                bounds = CGSize(width: bounds.height, height: bounds.width)
            }
            let screen = CGRect(x: r.minX * bounds.width, y: r.minY * bounds.height,
                                width: r.width * bounds.width, height: r.height * bounds.height)
            // The detected screen area is the bounding box of the bezel's rounded opening.
            // Round the content to match, or its square corners poke out past the bezel.
            let corner = FrameHoleCorner.radius(for: asset)
            return FrameGeometry(bounds: bounds, screen: screen, screenCorner: corner, bodyCorner: 0,
                                 asset: asset, rotateAsset: rotate)
        }
    }

    static func placeholderContentSize(_ config: RenderConfig) -> CGSize {
        config.spec.pixelSize
    }

    static func layout(canvas: CGSize, content: CGSize?, config: RenderConfig) -> (CanvasLayout, FrameGeometry, CGFloat) {
        let W = canvas.width, H = canvas.height
        let p = config.profile
        let pad = CGFloat(p.background.padding) * min(W, H)
        let margin = max(pad, min(W, H) * 0.025)
        var L = CanvasLayout()
        L.canvasSize = canvas
        var top = pad, bottom = H - pad

        if p.header.enabled {
            let hh = CGFloat(p.header.height) * H
            let r = CGRect(x: margin, y: margin * 0.6, width: W - 2 * margin, height: hh)
            L.headerRect = r
            top = max(top, r.maxY + margin * 0.5)
        }
        if p.footer.enabled {
            let fh = CGFloat(p.footer.height) * H
            let r = CGRect(x: margin, y: H - margin * 0.6 - fh, width: W - 2 * margin, height: fh)
            L.footerRect = r
            bottom = min(bottom, r.minY - margin * 0.5)
        }

        // Presenter webcam and nameplate. Side by side gives the webcam its own column and
        // shifts the device into what's left; a corner tile floats over the canvas.
        var left = pad, right = W - pad
        let cam = p.webcam, plate = p.nameplate
        let placement = plate.placement(with: cam)
        let attached = plate.enabled && placement != .corner     // card sits above or below the webcam
        let sideLayout = cam.enabled && cam.layout == .side
        let gap = margin * 0.6
        let colW = min(max(CGFloat(cam.size), sideLayout ? 0.12 : 0.08), 0.45) * W
        let plateSize = plate.enabled
            ? nameplateMetrics(plate, tokens: config.tokens, canvas: canvas,
                               maxWidth: attached ? (sideLayout ? colW : max(colW, W * 0.3)) : W * 0.5).size
            : nil
        func cornerRect(_ corner: CanvasCorner, _ size: CGSize) -> CGRect {
            CGRect(x: corner.isLeft ? margin : W - margin - size.width,
                   y: corner.isTop ? max(top, margin) : min(bottom, H - margin) - size.height,
                   width: size.width, height: size.height)
        }
        /// Puts the card above or below the webcam tile, centered on it and kept on the canvas.
        func attach(_ ps: CGSize, to tile: CGRect) -> CGRect {
            let wanted: CGFloat
            switch plate.align {
            case .left: wanted = tile.minX
            case .center: wanted = tile.midX - ps.width / 2
            case .right: wanted = tile.maxX - ps.width
            }
            let x = min(max(wanted, margin), W - margin - ps.width)
            let y = placement == .aboveWebcam ? tile.minY - gap - ps.height : tile.maxY + gap
            return CGRect(x: x, y: y, width: ps.width, height: ps.height)
        }

        if sideLayout {
            let colX = cam.side == .left ? margin : W - margin - colW
            let colH = max(10, bottom - top)
            let plateH = attached ? (plateSize.map { $0.height + gap } ?? 0) : 0
            let tileH = min(cam.shape == .circle ? colW : colW * 0.75, colH - plateH)
            let tileW = cam.shape == .circle ? tileH : colW
            // The tile and its card are centered in the column as one group.
            let groupTop = top + (colH - tileH - plateH) / 2
            let tileY = placement == .aboveWebcam && attached ? groupTop + plateH : groupTop
            let tile = CGRect(x: colX + (colW - tileW) / 2, y: tileY, width: tileW, height: tileH)
            L.webcamRect = tile
            if attached, let ps = plateSize { L.nameplateRect = attach(ps, to: tile) }
            if cam.side == .left { left = max(left, colX + colW + margin) } else { right = min(right, colX - margin) }
        } else if cam.enabled {
            var tile = cornerRect(cam.corner, CGSize(width: colW, height: cam.shape == .circle ? colW : colW * 0.75))
            if attached, let ps = plateSize {
                // Make room when the card would fall off the edge the tile is tucked against.
                if placement == .belowWebcam, !cam.corner.isTop { tile.origin.y -= ps.height + gap }
                if placement == .aboveWebcam, cam.corner.isTop { tile.origin.y += ps.height + gap }
                L.nameplateRect = attach(ps, to: tile)
            }
            L.webcamRect = tile
        }
        if !attached, let ps = plateSize { L.nameplateRect = cornerRect(plate.corner, ps) }

        let avail = CGRect(x: left, y: top, width: max(10, right - left), height: max(10, bottom - top))
        let c = content ?? placeholderContentSize(config)
        let g = geometry(content: c, config: config)
        let s = min(avail.width / g.bounds.width, avail.height / g.bounds.height)
        let dw = g.bounds.width * s, dh = g.bounds.height * s
        L.deviceRect = CGRect(x: avail.midX - dw / 2, y: avail.midY - dh / 2, width: dw, height: dh)
        L.screenRect = CGRect(x: L.deviceRect.minX + g.screen.minX * s, y: L.deviceRect.minY + g.screen.minY * s,
                              width: g.screen.width * s, height: g.screen.height * s)
        L.hasDevice = content != nil
        return (L, g, s)
    }

    /// Canvas that shows the device screen at (roughly) its native resolution.
    static func autoCanvasSize(content: CGSize?, config: RenderConfig) -> CGSize {
        guard let c = content, c.width > 0, c.height > 0 else { return CGSize(width: 1920, height: 1080) }
        let g = geometry(content: c, config: config)
        let s0 = c.width / max(1, g.screen.width)
        let fw = g.bounds.width * s0, fh = g.bounds.height * s0
        let p = config.profile
        let pad = CGFloat(p.background.padding)
        var bands: CGFloat = 0
        if p.header.enabled { bands += CGFloat(p.header.height) + 0.04 }
        if p.footer.enabled { bands += CGFloat(p.footer.height) + 0.04 }
        var W = fw / max(0.3, 1 - 2 * pad)
        // Side by side: widen the canvas so the device keeps its size next to the webcam column.
        if p.webcam.enabled, p.webcam.layout == .side { W /= max(0.4, 1 - CGFloat(p.webcam.size) - 0.04) }
        var H = fh / max(0.3, 1 - 2 * pad - bands)
        let scale = min(1, config.maxAutoSide / max(W, H))
        W *= scale
        H *= scale
        return CGSize(width: max(320, (W / 8).rounded() * 8), height: max(320, (H / 8).rounded() * 8))
    }

    static func canvasSize(content: CGSize?, config: RenderConfig) -> CGSize {
        config.canvasPreset.fixedSize ?? autoCanvasSize(content: content, config: config)
    }

    static func needsPreviewExtras(_ p: PresenterSnapshot) -> Bool {
        p.tool == .redact || p.pendingRedaction != nil
    }

    static func aspectFillCrop(content cs: CGSize, target ts: CGSize) -> CGRect {
        guard ts.width > 0, ts.height > 0 else { return CGRect(origin: .zero, size: cs) }
        let targetAspect = ts.width / ts.height
        if cs.width / cs.height > targetAspect {
            let w = cs.height * targetAspect
            return CGRect(x: (cs.width - w) / 2, y: 0, width: w, height: cs.height)
        } else {
            let h = cs.width / targetAspect
            return CGRect(x: 0, y: (cs.height - h) / 2, width: cs.width, height: h)
        }
    }

    // MARK: Render

    /// `ctx` must already be flipped (origin top-left).
    @discardableResult
    func render(in ctx: CGContext, size: CGSize, device: DeviceInput?, config: RenderConfig,
                presenter: PresenterSnapshot, includeOverlays: Bool, now: CFTimeInterval, date: Date) -> CanvasLayout {
        frameCounter &+= 1
        let (L, g, s) = Self.layout(canvas: size, content: device?.size, config: config)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        ctx.interpolationQuality = .high
        drawBackdrop(ctx, size: size, layout: L, geometry: g, scale: s, config: config)
        drawDevice(ctx, layout: L, geometry: g, scale: s, device: device, config: config, bodyDrawn: true)
        if let r = L.webcamRect { drawWebcam(ctx, rect: r, cam: config.profile.webcam) }
        if let r = L.nameplateRect {
            drawNameplate(ctx, rect: r, plate: config.profile.nameplate, tokens: config.tokens, canvas: size, date: date)
        }

        if includeOverlays {
            let p = config.profile
            if p.watermark.enabled { drawWatermark(ctx, layout: L, wm: p.watermark, tokens: config.tokens, date: date) }
            if p.header.enabled, let r = L.headerRect { drawHeader(ctx, rect: r, header: p.header, tokens: config.tokens, date: date) }
            if p.footer.enabled, let r = L.footerRect { drawFooter(ctx, rect: r, footer: p.footer, tokens: config.tokens, date: date) }
        }
        drawPresenter(ctx, size: size, presenter: presenter, fade: config.annotationFade, now: now)
        return L
    }

    /// Draws just the framed device on transparency, cropped to the device body, for the
    /// frame-only output window. It uses the full canvas layout so presenter points (which are
    /// normalized to the canvas) land where they would on the canvas. Header, footer and
    /// background are left out; the watermark and presenter layer are clipped to the device.
    /// `ctx` must already be flipped (origin top-left) and sized to `outputSize`.
    @discardableResult
    func renderDeviceOnly(in ctx: CGContext, outputSize: CGSize, canvas: CGSize, device: DeviceInput?,
                          config: RenderConfig, presenter: PresenterSnapshot, includeOverlays: Bool,
                          now: CFTimeInterval, date: Date) -> CanvasLayout {
        frameCounter &+= 1
        let (L, g, s) = Self.layout(canvas: canvas, content: device?.size, config: config)
        guard L.deviceRect.width > 0 else { return L }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        ctx.clear(CGRect(origin: .zero, size: outputSize))
        ctx.interpolationQuality = .high
        ctx.saveGState()
        let k = outputSize.width / L.deviceRect.width
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -L.deviceRect.minX, y: -L.deviceRect.minY)

        drawDevice(ctx, layout: L, geometry: g, scale: s, device: device, config: config, allowShadow: false)

        // Keep overlays inside the device so nothing paints the transparent corners.
        ctx.addPath(roundedPath(L.deviceRect, Self.silhouetteCorner(layout: L, geometry: g, scale: s, spec: config.spec)))
        ctx.clip()
        if includeOverlays, config.profile.watermark.enabled {
            drawWatermark(ctx, layout: L, wm: config.profile.watermark, tokens: config.tokens, date: date)
        }
        drawPresenter(ctx, size: canvas, presenter: presenter, fade: config.annotationFade, now: now,
                      bitmapRect: L.deviceRect)
        ctx.restoreGState()
        return L
    }

    /// Corner radius of the device outline, in canvas pixels. Imported frame art has no
    /// corner value, so it is estimated from the model's proportions.
    static func silhouetteCorner(layout L: CanvasLayout, geometry g: FrameGeometry, scale s: CGFloat, spec: DeviceSpec) -> CGFloat {
        if g.asset == nil { return g.bodyCorner * s }
        return spec.bodyCornerRatio * min(L.screenRect.width, L.screenRect.height)
    }

    // MARK: Presenter webcam and nameplate

    private func drawWebcam(_ ctx: CGContext, rect: CGRect, cam: WebcamSettings) {
        let path = cam.shape == .circle ? CGPath(ellipseIn: rect, transform: nil)
                                        : roundedPath(rect, rect.width * 0.07)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: rect.height * 0.02), blur: rect.width * 0.08,
                      color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let img = webcamImage {
            let size = CGSize(width: img.width, height: img.height)
            let crop = Self.aspectFillCrop(content: size, target: rect.size)
            let k = rect.width / crop.width
            if cam.mirrored {
                ctx.translateBy(x: rect.midX * 2, y: 0)
                ctx.scaleBy(x: -1, y: 1)
            }
            drawImage(ctx, img, in: CGRect(x: rect.minX - crop.minX * k, y: rect.minY - crop.minY * k,
                                           width: size.width * k, height: size.height * k))
        } else {
            let a = attributed("Starting camera…", size: rect.width * 0.07, weight: .medium, color: RGBAColor(1, 1, 1, 0.6))
            let ts = a.size()
            a.draw(at: CGPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2))
        }
        ctx.restoreGState()

        if cam.border {
            let lw = max(2, rect.width * 0.012)
            ctx.addPath(cam.shape == .circle ? CGPath(ellipseIn: rect.insetBy(dx: lw / 2, dy: lw / 2), transform: nil)
                                             : roundedPath(rect.insetBy(dx: lw / 2, dy: lw / 2), rect.width * 0.07 - lw / 2))
            ctx.setStrokeColor(cam.borderColor.cgColor)
            ctx.setLineWidth(lw)
            ctx.strokePath()
        }
    }

    private func drawNameplate(_ ctx: CGContext, rect: CGRect, plate: NameplateSettings, tokens: TokenContext,
                               canvas: CGSize, date: Date) {
        let m = Self.nameplateMetrics(plate, tokens: tokens, canvas: canvas, maxWidth: rect.width, date: date)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2 * m.unit), blur: 12 * m.unit, color: CGColor(gray: 0, alpha: 0.3))
        let radius = min(rect.height * 0.28, 18 * m.unit)
        ctx.addPath(roundedPath(rect, radius))
        ctx.setFillColor(plate.background.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        if plate.border {
            let lw = max(2, 3 * m.unit)
            ctx.addPath(roundedPath(rect.insetBy(dx: lw / 2, dy: lw / 2), max(0, radius - lw / 2)))
            ctx.setStrokeColor(plate.borderColor.cgColor)
            ctx.setLineWidth(lw)
            ctx.strokePath()
        }

        var x = rect.minX + m.padding
        if let logo = m.logo {
            // An icon: a square slot with rounded corners, the image fitted inside it.
            let side = rect.height - 2 * m.padding
            let slot = CGRect(x: x, y: rect.minY + m.padding, width: side, height: side)
            let k = min(side / CGFloat(max(1, logo.width)), side / CGFloat(max(1, logo.height)))
            let iw = CGFloat(logo.width) * k, ih = CGFloat(logo.height) * k
            ctx.saveGState()
            ctx.addPath(roundedPath(slot, side * 0.22))
            ctx.clip()
            drawImage(ctx, logo, in: CGRect(x: slot.midX - iw / 2, y: slot.midY - ih / 2, width: iw, height: ih))
            ctx.restoreGState()
            x += side + m.padding * 0.8
        }
        var y = rect.midY - m.textHeight / 2
        for line in m.lines {
            line.draw(at: CGPoint(x: x, y: y))
            y += line.size().height
        }
    }

    struct NameplateMetrics {
        var size: CGSize = .zero
        var unit: CGFloat = 1
        var padding: CGFloat = 0
        var textHeight: CGFloat = 0
        var lines: [NSAttributedString] = []
        var logo: CGImage?
    }

    /// Sizes the nameplate card for its text and logo, shrinking it to fit `maxWidth`.
    static func nameplateMetrics(_ plate: NameplateSettings, tokens: TokenContext, canvas: CGSize, maxWidth: CGFloat,
                                 date: Date = Date()) -> NameplateMetrics {
        func build(_ unit: CGFloat) -> NameplateMetrics {
            var m = NameplateMetrics()
            m.unit = unit
            m.padding = 14 * unit
            let name = Tokens.resolve(plate.name, tokens, date: date).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { m.lines.append(attributed(name, size: 30 * unit, weight: .semibold, color: plate.textColor)) }
            // Title and company each get their own line under the name.
            for text in [plate.title, plate.company] {
                let line = Tokens.resolve(text, tokens, date: date).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                m.lines.append(attributed(line, size: 20 * unit, weight: .regular,
                                          color: plate.textColor.withAlpha(plate.textColor.a * 0.8)))
            }
            let textW = m.lines.map { $0.size().width }.max() ?? 0
            m.textHeight = m.lines.reduce(0) { $0 + $1.size().height }
            let contentH = max(m.textHeight, 44 * unit)
            var width = m.padding * 2 + textW
            m.logo = AssetStore.shared.asset(plate.logoFile)
            if m.logo != nil { width += contentH + (textW > 0 ? m.padding * 0.8 : 0) }   // square icon slot
            m.size = CGSize(width: width.rounded(.up), height: (contentH + m.padding * 2).rounded(.up))
            return m
        }
        let unit = canvas.height / 1080 * CGFloat(plate.scale)
        var m = build(unit)
        if m.size.width > maxWidth, maxWidth > 20 { m = build(unit * maxWidth / m.size.width * 0.99) }
        return m
    }

    // MARK: Background

    private func drawBackground(_ ctx: CGContext, size: CGSize, bg: BackgroundSettings) {
        let rect = CGRect(origin: .zero, size: size)
        switch bg.style {
        case .solid:
            ctx.setFillColor(bg.color1.cgColor)
            ctx.fill(rect)
        case .gradient:
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: [bg.color1.cgColor, bg.color2.cgColor] as CFArray,
                                         locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width * 0.6, y: size.height),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        case .image:
            ctx.setFillColor(bg.color1.cgColor)
            ctx.fill(rect)
            if let img = AssetStore.shared.asset(bg.imageFile) {
                let iw = CGFloat(img.width), ih = CGFloat(img.height)
                let k = max(size.width / iw, size.height / ih)
                let r = CGRect(x: (size.width - iw * k) / 2, y: (size.height - ih * k) / 2, width: iw * k, height: ih * k)
                drawImage(ctx, img, in: r)
            }
        }
    }

    // MARK: Backdrop

    private func drawBackdrop(_ ctx: CGContext, size: CGSize, layout L: CanvasLayout, geometry g: FrameGeometry,
                              scale s: CGFloat, config: RenderConfig) {
        let bg = config.profile.background
        let backgroundImage = bg.style == .image ? AssetStore.shared.asset(bg.imageFile) : nil
        var frameImage: CGImage?
        let frame: BackdropKey.Frame
        switch config.frame {
        case .none: frame = .none
        case .procedural(let color): frame = .procedural(color)
        case .image:
            frame = .image
            if let asset = g.asset { frameImage = g.rotateAsset ? rotatedCCW(asset.image) : asset.image }
        }
        let key = BackdropKey(size: size, background: bg, frame: frame, body: L.deviceRect, screen: L.screenRect,
                              bodyCorner: g.bodyCorner * s, screenCorner: g.screenCorner * s, spec: config.spec,
                              shadow: Self.shadowOn(config))
        func paint(_ c: CGContext) {
            drawBackground(c, size: size, bg: bg)
            drawBody(c, layout: L, geometry: g, scale: s, config: config, shadowOn: key.shadow, frameImage: frameImage)
        }

        var image: CGImage?
        if let i = backdrops.firstIndex(where: {
            $0.key == key && $0.backgroundImage === backgroundImage && $0.frameImage === frameImage
        }) {
            image = backdrops[i].image
            if i != backdrops.count - 1 { backdrops.append(backdrops.remove(at: i)) }   // most recent last
        } else if let c = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                    bytesPerRow: 0, space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            c.translateBy(x: 0, y: size.height)
            c.scaleBy(x: 1, y: -1)
            c.interpolationQuality = .high
            paint(c)
            image = c.makeImage()
            if let image {
                // One for the canvas and one for the virtual camera's size, plus one to spare.
                if backdrops.count >= 3 { backdrops.removeFirst() }
                backdrops.append((key, backgroundImage, frameImage, image))
            }
        }
        guard let image else { paint(ctx); return }
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        drawImage(ctx, image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    // MARK: Device

    private func rotatedCCW(_ image: CGImage) -> CGImage {
        let key = ObjectIdentifier(image)
        if let hit = rotatedCache[key] { return hit.rotated }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.translateBy(x: CGFloat(h), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return image }
        if rotatedCache.count > 8 { rotatedCache.removeAll() }
        rotatedCache[key] = (image, out)
        return out
    }

    private func drawDevice(_ ctx: CGContext, layout L: CanvasLayout, geometry g: FrameGeometry, scale s: CGFloat,
                            device: DeviceInput?, config: RenderConfig, allowShadow: Bool = true,
                            bodyDrawn: Bool = false) {
        let spec = config.spec
        let screen = L.screenRect
        let body = L.deviceRect
        var frameImage: CGImage?
        if let asset = g.asset { frameImage = g.rotateAsset ? rotatedCCW(asset.image) : asset.image }

        // 1. Body / shadow (already there when the backdrop was copied in)
        if !bodyDrawn {
            drawBody(ctx, layout: L, geometry: g, scale: s, config: config,
                     shadowOn: allowShadow && Self.shadowOn(config), frameImage: frameImage)
        }

        // 2. Screen content (clipped)
        ctx.saveGState()
        ctx.addPath(roundedPath(screen, g.screenCorner * s))
        ctx.clip()
        if let device {
            let crop = Self.aspectFillCrop(content: device.size, target: screen.size)
            drawScreen(ctx, device: device, crop: crop, in: screen)
            drawRedactions(ctx, screen: screen, crop: crop, device: device, redactions: config.profile.redactions)
            if config.profile.statusBar.enabled {
                drawStatusBar(ctx, screen: screen, crop: crop, device: device, spec: spec, sb: config.profile.statusBar)
            }
        } else {
            drawPlaceholder(ctx, screen: screen)
        }
        ctx.restoreGState()

        // 3. Details on top
        switch config.frame {
        case .procedural:
            drawDetails(ctx, spec: spec, body: body, screen: screen)
        case .image:
            if let frameImage { drawImage(ctx, frameImage, in: body) }
        case .none:
            break
        }
    }

    private static func shadowOn(_ config: RenderConfig) -> Bool {
        config.profile.background.padding > 0.005
    }

    /// The device body under the screen content, with its drop shadow.
    private func drawBody(_ ctx: CGContext, layout L: CanvasLayout, geometry g: FrameGeometry, scale s: CGFloat,
                          config: RenderConfig, shadowOn: Bool, frameImage: CGImage?) {
        let spec = config.spec
        let screen = L.screenRect
        let body = L.deviceRect
        let ss = min(screen.width, screen.height)
        switch config.frame {
        case .procedural(let color):
            let bodyCorner = g.bodyCorner * s
            let bodyPath = roundedPath(body, bodyCorner)
            ctx.saveGState()
            if shadowOn {
                ctx.setShadow(offset: CGSize(width: 0, height: body.height * 0.012), blur: body.width * 0.05,
                              color: CGColor(gray: 0, alpha: 0.45))
            }
            ctx.addPath(bodyPath)
            ctx.setFillColor(color.body.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.addPath(bodyPath)
            ctx.setStrokeColor(color.rim.cgColor)
            ctx.setLineWidth(max(1, body.width * 0.003))
            ctx.strokePath()

            let rim = spec.hasHomeButton ? body.width * 0.008
                : spec.sideBezelRatio * ss * (spec.family == .iPad ? 0.28 : 0.38)
            let glass = body.insetBy(dx: rim, dy: rim)
            ctx.addPath(roundedPath(glass, max(0, bodyCorner - rim)))
            ctx.setFillColor(spec.hasHomeButton ? color.homeFront.cgColor : CGColor(gray: 0.02, alpha: 1))
            ctx.fillPath()
        case .image:
            if let frameImage, shadowOn {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: body.height * 0.012), blur: body.width * 0.05,
                              color: CGColor(gray: 0, alpha: 0.45))
                drawImage(ctx, frameImage, in: body)
                ctx.restoreGState()
            }
        case .none:
            if shadowOn {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: screen.height * 0.01), blur: screen.width * 0.04,
                              color: CGColor(gray: 0, alpha: 0.45))
                ctx.addPath(roundedPath(screen, g.screenCorner * s))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fillPath()
                ctx.restoreGState()
            }
        }
    }

    /// Draws the part of the device frame in `crop` so that it fills `screen`.
    ///
    /// Core Graphics takes about 12 ms to resample a phone-sized image, however it is asked to
    /// do it, but about 1 ms to copy one pixel for pixel. So the frame is resampled with vImage
    /// to the exact pixel size it will cover, once per device frame, and then copied in.
    private func drawScreen(_ ctx: CGContext, device: DeviceInput, crop: CGRect, in screen: CGRect) {
        let m = ctx.ctm
        let target = screen.applying(m)   // the same space the image is drawn in below
        let pixels = CGRect(x: target.minX.rounded(), y: target.minY.rounded(),
                            width: max(1, target.width.rounded()), height: max(1, target.height.rounded()))
        if m.b == 0, m.c == 0,
           let image = screenImage(device: device, crop: crop, width: Int(pixels.width), height: Int(pixels.height)) {
            ctx.saveGState()
            ctx.concatenate(m.inverted())   // draw in pixels: the bitmap's own space is upright
            ctx.draw(image, in: pixels)
            ctx.restoreGState()
            return
        }
        let cs = device.size
        let k = screen.width / crop.width
        drawImage(ctx, device.image, in: CGRect(x: screen.minX - crop.minX * k, y: screen.minY - crop.minY * k,
                                               width: cs.width * k, height: cs.height * k))
    }

    private func screenImage(device: DeviceInput, crop: CGRect, width: Int, height: Int) -> CGImage? {
        let pb = device.pixelBuffer
        // Entries for earlier frames go first, so capture buffers return to their pool promptly.
        scaledScreens.removeAll { $0.buffer !== pb }
        if let hit = scaledScreens.first(where: { $0.crop == crop && $0.width == width && $0.height == height }) {
            return hit.image
        }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA, !CVPixelBufferIsPlanar(pb) else { return nil }
        let full = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        let src = crop.integral.intersection(full)
        guard !src.isNull, src.width >= 1, src.height >= 1 else { return nil }
        if src == full, width == Int(full.width), height == Int(full.height) { return device.image }

        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pb)
        var source = vImage_Buffer(data: base + Int(src.minY) * srcRowBytes + Int(src.minX) * 4,
                                   height: vImagePixelCount(src.height), width: vImagePixelCount(src.width),
                                   rowBytes: srcRowBytes)
        let rowBytes = width * 4
        guard let memory = malloc(rowBytes * height) else { return nil }
        var dest = vImage_Buffer(data: memory, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                 rowBytes: rowBytes)
        guard vImageScale_ARGB8888(&source, &dest, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError,
              let provider = CGDataProvider(dataInfo: nil, data: memory, size: rowBytes * height,
                                            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) })
        else { free(memory); return nil }
        // Same pixel layout and color space as the device image, so colors come out identical.
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: device.image.colorSpace ?? colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        scaledScreens.append((pb, crop, width, height, image))
        return image
    }

    private func drawDetails(_ ctx: CGContext, spec: DeviceSpec, body: CGRect, screen: CGRect) {
        let ss = min(screen.width, screen.height)
        let landscape = screen.width > screen.height
        ctx.saveGState()
        switch spec.topFeature {
        case .dynamicIsland:
            let w = 0.318 * ss, h = 0.095 * ss, off = 0.03 * ss
            let r = landscape
                ? CGRect(x: screen.minX + off, y: screen.midY - w / 2, width: h, height: w)
                : CGRect(x: screen.midX - w / 2, y: screen.minY + off, width: w, height: h)
            ctx.addPath(roundedPath(r, min(r.width, r.height) / 2))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
        case .notch:
            let w = 0.415 * ss, h = 0.085 * ss, extra = 0.05 * ss
            let r = landscape
                ? CGRect(x: screen.minX - extra, y: screen.midY - w / 2, width: h + extra, height: w)
                : CGRect(x: screen.midX - w / 2, y: screen.minY - extra, width: w, height: h + extra)
            ctx.addPath(roundedPath(r, extra * 0.9))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
        case .cameraDot:
            let rad = max(1.5, 0.007 * ss)
            let c = landscape
                ? CGPoint(x: (body.minX + screen.minX) / 2, y: screen.midY)
                : CGPoint(x: screen.midX, y: (body.minY + screen.minY) / 2)
            ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
            ctx.setFillColor(CGColor(red: 0.15, green: 0.18, blue: 0.3, alpha: 1))
            let ir = rad * 0.45
            ctx.fillEllipse(in: CGRect(x: c.x - ir, y: c.y - ir, width: ir * 2, height: ir * 2))
        case .none:
            break
        }
        if spec.hasHomeButton {
            let rad = (spec.family == .iPad ? 0.036 : 0.085) * ss
            let c = landscape
                ? CGPoint(x: (screen.maxX + body.maxX) / 2, y: screen.midY)
                : CGPoint(x: screen.midX, y: (screen.maxY + body.maxY) / 2)
            ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.6))
            ctx.setLineWidth(max(1, rad * 0.08))
            ctx.strokeEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
        }
        ctx.restoreGState()
    }

    private func drawPlaceholder(_ ctx: CGContext, screen: CGRect) {
        if let gradient = CGGradient(colorsSpace: colorSpace,
                                     colors: [CGColor(gray: 0.16, alpha: 1), CGColor(gray: 0.08, alpha: 1)] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: screen.midX, y: screen.minY),
                                   end: CGPoint(x: screen.midX, y: screen.maxY), options: [])
        }
        let ss = min(screen.width, screen.height)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = ss * 0.02
        let text = NSMutableAttributedString(string: "Connect an iPhone or iPad with a USB cable\n", attributes: [
            .font: NSFont.systemFont(ofSize: ss * 0.05, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.85),
            .paragraphStyle: para,
        ])
        text.append(NSAttributedString(string: "Unlock it and tap “Trust” if asked", attributes: [
            .font: NSFont.systemFont(ofSize: ss * 0.035),
            .foregroundColor: NSColor(white: 1, alpha: 0.55),
            .paragraphStyle: para,
        ]))
        let box = screen.insetBy(dx: ss * 0.1, dy: 0)
        let h = text.boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin]).height
        text.draw(with: CGRect(x: box.minX, y: screen.midY - h / 2, width: box.width, height: h),
                  options: [.usesLineFragmentOrigin])
    }

    // MARK: Redactions

    private func drawRedactions(_ ctx: CGContext, screen: CGRect, crop: CGRect, device: DeviceInput, redactions: [Redaction]) {
        guard !redactions.isEmpty else { return }
        let cs = device.size
        var base: CIImage?
        for r in redactions {
            let dst = CGRect(x: screen.minX + r.rect.minX * screen.width, y: screen.minY + r.rect.minY * screen.height,
                             width: r.rect.width * screen.width, height: r.rect.height * screen.height)
            switch r.style {
            case .solid:
                ctx.setFillColor(r.color.cgColor)
                ctx.fill(dst)
            case .blur, .pixelate:
                let src = CGRect(x: crop.minX + r.rect.minX * crop.width, y: crop.minY + r.rect.minY * crop.height,
                                 width: r.rect.width * crop.width, height: r.rect.height * crop.height)
                    .intersection(CGRect(origin: .zero, size: cs))
                guard !src.isNull, src.width >= 1, src.height >= 1 else { continue }
                let ciRect = CGRect(x: src.minX, y: cs.height - src.maxY, width: src.width, height: src.height)
                if base == nil { base = CIImage(cvPixelBuffer: device.pixelBuffer).clampedToExtent() }
                guard let b = base else { continue }
                let out: CIImage
                if r.style == .blur {
                    out = b.applyingGaussianBlur(sigma: Double(max(10, cs.width / 40)))
                } else {
                    let f = CIFilter.pixellate()
                    f.inputImage = b
                    f.scale = Float(max(12, cs.width / 40))
                    f.center = CGPoint(x: ciRect.minX, y: ciRect.minY)
                    out = f.outputImage ?? b
                }
                if let cg = ciContext.createCGImage(out.cropped(to: ciRect), from: ciRect) {
                    drawImage(ctx, cg, in: dst)
                }
            }
        }
    }

    // MARK: Status bar

    private func sampledStatusColor(device: DeviceInput, crop: CGRect) -> RGBAColor {
        statusColorAge += 1
        if statusColorAge < 10 { return statusColor }
        statusColorAge = 0
        let cs = device.size
        // A thin strip along the very top edge (above any status bar text).
        let stripH = max(2, crop.height * 0.004)
        let ciRect = CGRect(x: crop.minX, y: cs.height - crop.minY - stripH, width: crop.width, height: stripH)
        let f = CIFilter.areaAverage()
        f.inputImage = CIImage(cvPixelBuffer: device.pixelBuffer)
        f.extent = ciRect
        guard let out = f.outputImage else { return statusColor }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: colorSpace)
        statusColor = RGBAColor(Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
        return statusColor
    }

    private func symbol(_ name: String, pointSize: CGFloat, color: RGBAColor) -> NSImage? {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? (name == "battery.100percent" ? NSImage(systemSymbolName: "battery.100", accessibilityDescription: nil) : nil)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color.nsColor]))
        return base?.withSymbolConfiguration(config)
    }

    private func drawStatusBar(_ ctx: CGContext, screen: CGRect, crop: CGRect, device: DeviceInput,
                               spec: DeviceSpec, sb: StatusBarSettings) {
        let landscape = device.size.width > device.size.height
        if spec.family == .iPhone && landscape { return } // iOS hides it in landscape on iPhone
        let specH = landscape ? spec.pixelSize.width : spec.pixelSize.height
        let barH = spec.statusBarPoints * spec.scale / specH * screen.height
        guard barH > 2 else { return }
        let bar = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: barH)
        let bg = sb.autoColor ? sampledStatusColor(device: device, crop: crop) : sb.background
        let fg = sb.autoColor ? bg.contrasting : sb.foreground
        ctx.setFillColor(bg.cgColor)
        ctx.fill(bar)

        let isPad = spec.family == .iPad
        let fs = barH * (isPad ? 0.5 : 0.32)
        let timeText = (isPad && !sb.iPadDate.isEmpty) ? "\(sb.time)  \(sb.iPadDate)" : sb.time
        let timeA = attributed(timeText, size: fs, weight: .semibold, color: fg)
        let ts = timeA.size()
        let centerY = isPad ? bar.midY : bar.minY + barH * 0.56
        let margin = barH * 0.9
        let timeX = isPad ? bar.minX + margin : bar.minX + bar.width * 0.2 - ts.width / 2
        timeA.draw(at: CGPoint(x: timeX, y: centerY - ts.height / 2))

        var names: [String] = []
        if sb.showCellular && !isPad { names.append("cellularbars") }
        names.append("wifi")
        names.append("battery.100percent")
        let icons = names.compactMap { symbol($0, pointSize: fs * 0.9, color: fg) }
        let gap = fs * 0.35
        let total = icons.reduce(CGFloat(0)) { $0 + $1.size.width } + gap * CGFloat(max(0, icons.count - 1))
        var x = isPad ? bar.maxX - margin - total : bar.minX + bar.width * 0.8 - total / 2
        for icon in icons {
            let sz = icon.size
            icon.draw(in: CGRect(x: x, y: centerY - sz.height / 2, width: sz.width, height: sz.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += sz.width + gap
        }
    }

    // MARK: Overlays

    private func drawWatermark(_ ctx: CGContext, layout L: CanvasLayout, wm: WatermarkSettings, tokens: TokenContext, date: Date) {
        let size = L.canvasSize
        let area = (wm.scope == .device && L.hasDevice) ? L.screenRect : CGRect(origin: .zero, size: size)
        let unit = size.height / 1080
        let itemSize: CGSize
        let drawItem: (CGPoint) -> Void

        if wm.useImage, let img = AssetStore.shared.asset(wm.imageFile) {
            let w = CGFloat(wm.imageWidth) * area.width
            let h = w * CGFloat(img.height) / CGFloat(max(1, img.width))
            itemSize = CGSize(width: w, height: h)
            drawItem = { c in drawImage(ctx, img, in: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)) }
        } else {
            let text = Tokens.resolve(wm.text, tokens, date: date)
            guard !text.isEmpty else { return }
            let a = attributed(text, size: CGFloat(wm.fontSize) * unit, weight: .semibold, color: wm.color)
            let ts = a.size()
            itemSize = ts
            drawItem = { c in a.draw(at: CGPoint(x: c.x - ts.width / 2, y: c.y - ts.height / 2)) }
        }

        ctx.saveGState()
        ctx.clip(to: area)
        ctx.setAlpha(CGFloat(wm.opacity))
        ctx.translateBy(x: area.midX, y: area.midY)
        ctx.rotate(by: CGFloat(wm.angle) * .pi / 180)
        if wm.tiled {
            let spacing = CGFloat(max(0.3, wm.spacing))
            let stepX = max(20, (itemSize.width + max(itemSize.height * 2, itemSize.width * 0.35)) * spacing)
            let stepY = max(20, itemSize.height * 3.2 * spacing)
            let half = hypot(area.width, area.height) / 2 + max(stepX, stepY)
            var row = 0
            var y = -half
            while y <= half {
                var x = -half + (row % 2 == 0 ? 0 : stepX / 2)
                while x <= half {
                    drawItem(CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
                row += 1
            }
        } else {
            drawItem(.zero)
        }
        ctx.restoreGState()
    }

    private func drawHeader(_ ctx: CGContext, rect r: CGRect, header h: HeaderSettings, tokens: TokenContext, date: Date) {
        let logo = AssetStore.shared.asset(h.logoFile)
        var logoH = r.height * 0.8
        var logoW: CGFloat = 0
        if let logo {
            logoW = logoH * CGFloat(logo.width) / CGFloat(max(1, logo.height))
            let maxW = r.width * 0.35
            if logoW > maxW {
                logoH *= maxW / logoW
                logoW = maxW
            }
        }
        let title = Tokens.resolve(h.title, tokens, date: date)
        let titleA = attributed(title, size: r.height * 0.36, weight: .semibold, color: h.textColor)
        let ts = title.isEmpty ? CGSize.zero : titleA.size()
        let gap = (logo != nil && !title.isEmpty) ? r.height * 0.3 : 0
        let total = logoW + gap + ts.width
        var x: CGFloat
        switch h.alignment {
        case .left: x = r.minX
        case .center: x = r.midX - total / 2
        case .right: x = r.maxX - total
        }
        if let logo {
            drawImage(ctx, logo, in: CGRect(x: x, y: r.midY - logoH / 2, width: logoW, height: logoH))
            x += logoW + gap
        }
        if !title.isEmpty { titleA.draw(at: CGPoint(x: x, y: r.midY - ts.height / 2)) }

        let right = Tokens.resolve(h.rightText, tokens, date: date)
        if !right.isEmpty && h.alignment != .right {
            let ra = attributed(right, size: r.height * 0.26, color: h.textColor.withAlpha(h.textColor.a * 0.75))
            let rs = ra.size()
            ra.draw(at: CGPoint(x: r.maxX - rs.width, y: r.midY - rs.height / 2))
        }
        if h.showDivider {
            let y = r.maxY + r.height * 0.15
            ctx.setStrokeColor(h.textColor.withAlpha(0.2).cgColor)
            ctx.setLineWidth(max(1, r.height * 0.015))
            ctx.strokeLineSegments(between: [CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y)])
        }
    }

    private func drawFooter(_ ctx: CGContext, rect r: CGRect, footer f: FooterSettings, tokens: TokenContext, date: Date) {
        if f.showDivider {
            let y = r.minY - r.height * 0.2
            ctx.setStrokeColor(f.textColor.withAlpha(0.2).cgColor)
            ctx.setLineWidth(max(1, r.height * 0.02))
            ctx.strokeLineSegments(between: [CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y)])
        }
        var fs = r.height * 0.4
        let text = Tokens.resolve(f.text, tokens, date: date)
        let badge = Tokens.resolve(f.badge, tokens, date: date)

        func measure(_ fs: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            let bw = badge.isEmpty ? 0 : attributed(badge, size: fs * 0.85, weight: .bold, color: .white).size().width + fs * 1.0
            let tw = text.isEmpty ? 0 : attributed(text, size: fs, color: f.textColor).size().width
            let gap = (!badge.isEmpty && !text.isEmpty) ? fs * 0.8 : 0
            return (bw, tw, gap)
        }
        var (bw, tw, gap) = measure(fs)
        if bw + gap + tw > r.width {
            fs *= max(0.6, r.width / (bw + gap + tw))
            (bw, tw, gap) = measure(fs)
        }
        let total = min(r.width, bw + gap + tw)
        var x: CGFloat
        switch f.alignment {
        case .left: x = r.minX
        case .center: x = r.midX - total / 2
        case .right: x = r.maxX - total
        }
        if !badge.isEmpty {
            let ba = attributed(badge, size: fs * 0.85, weight: .bold, color: f.badgeColor.contrasting)
            let bs = ba.size()
            let pill = CGRect(x: x, y: r.midY - bs.height / 2 - fs * 0.2, width: bw, height: bs.height + fs * 0.4)
            ctx.addPath(roundedPath(pill, pill.height * 0.3))
            ctx.setFillColor(f.badgeColor.cgColor)
            ctx.fillPath()
            ba.draw(at: CGPoint(x: pill.midX - bs.width / 2, y: pill.midY - bs.height / 2))
            x += bw + gap
        }
        if !text.isEmpty {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let ta = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: max(1, fs)),
                .foregroundColor: f.textColor.nsColor,
                .paragraphStyle: para,
            ])
            let th = ta.size().height
            ta.draw(with: CGRect(x: x, y: r.midY - th / 2, width: max(1, r.maxX - x), height: th),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    // MARK: Presenter

    /// `bitmapRect` is the area (in the current user space) that the context's bitmap covers;
    /// the zoom lens magnifies a snapshot of that bitmap.
    private func drawPresenter(_ ctx: CGContext, size: CGSize, presenter p: PresenterSnapshot, fade: Double, now: CFTimeInterval,
                               bitmapRect: CGRect? = nil) {
        let H = size.height
        func pt(_ n: CGPoint) -> CGPoint { CGPoint(x: n.x * size.width, y: n.y * size.height) }

        // Strokes
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for s in p.strokes {
            var alpha: CGFloat = 1
            if fade > 0, let ended = s.endedAt {
                let over = now - ended - fade
                if over > 0 { alpha = max(0, 1 - CGFloat(over / 0.5)) }
            }
            guard alpha > 0, let first = s.points.first else { continue }
            let color = s.color.withAlpha((s.highlighter ? 0.38 : 1) * Double(alpha)).cgColor
            let width = max(1, s.width * H)
            if s.points.count == 1 {
                let c = pt(first)
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: c.x - width / 2, y: c.y - width / 2, width: width, height: width))
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(width)
                ctx.beginPath()
                ctx.move(to: pt(first))
                for q in s.points.dropFirst() { ctx.addLine(to: pt(q)) }
                ctx.strokePath()
            }
        }
        ctx.restoreGState()

        // Click ripples
        for click in p.clicks {
            let age = now - click.time
            guard age >= 0, age < 0.5 else { continue }
            let c = pt(click.point)
            let r = (0.012 + CGFloat(age) * 0.07) * H
            ctx.setStrokeColor(RGBAColor.yellow.withAlpha(0.8 * (1 - age / 0.5)).cgColor)
            ctx.setLineWidth(max(1.5, H * 0.004))
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        guard let cursor = p.cursor else { return }
        let c = pt(cursor)
        switch p.tool {
        case .pointer where p.highlightCursor:
            Self.drawPointerHighlight(ctx, size: size, cursor: cursor)
        case .spotlight:
            let r = p.spotlightRadius * H
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: size))
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.62))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        case .zoom:
            guard let snapshot = ctx.makeImage() else { return }
            let r = p.lensRadius * H
            let z = p.zoomFactor
            let lens = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: r * 0.25, color: CGColor(gray: 0, alpha: 0.5))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillEllipse(in: lens)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addEllipse(in: lens)
            ctx.clip()
            let b = bitmapRect ?? CGRect(origin: .zero, size: size)
            drawImage(ctx, snapshot, in: CGRect(x: c.x + (b.minX - c.x) * z, y: c.y + (b.minY - c.y) * z,
                                                width: b.width * z, height: b.height * z))
            ctx.restoreGState()
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(max(2, H * 0.004))
            ctx.strokeEllipse(in: lens)
        default:
            break
        }
    }

    /// Pointer highlight radius as a fraction of canvas height. The preview draws its own copy
    /// of the highlight as a layer (so it tracks the mouse instantly) and must match this.
    static let pointerHighlightRadius: CGFloat = 0.022

    /// The yellow pointer highlight. `ctx` is flipped; `cursor` is normalized to the canvas.
    static func drawPointerHighlight(_ ctx: CGContext, size: CGSize, cursor: CGPoint) {
        let H = size.height
        let c = CGPoint(x: cursor.x * size.width, y: cursor.y * H)
        let r = H * pointerHighlightRadius
        ctx.setFillColor(RGBAColor.yellow.withAlpha(0.35).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.setStrokeColor(RGBAColor.yellow.withAlpha(0.7).cgColor)
        ctx.setLineWidth(max(1, H * 0.002))
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    // MARK: Preview-only extras (never recorded)
    // Only editing guides belong here. Messages for the presenter (hints, the countdown)
    // are shown in the app's own UI, never painted over the output.

    func previewExtras(on image: CGImage, layout L: CanvasLayout, config: RenderConfig, presenter p: PresenterSnapshot) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let size = CGSize(width: w, height: h)
        let unit = size.height / 1080
        let pink = RGBAColor(1, 0.25, 0.55)

        if p.tool == .redact && L.hasDevice {
            let s = L.screenRect
            ctx.setLineWidth(max(1, 2 * unit))
            ctx.setLineDash(phase: 0, lengths: [8 * unit, 5 * unit])
            ctx.setStrokeColor(pink.cgColor)
            for r in config.profile.redactions {
                ctx.stroke(CGRect(x: s.minX + r.rect.minX * s.width, y: s.minY + r.rect.minY * s.height,
                                  width: r.rect.width * s.width, height: r.rect.height * s.height))
            }
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if let pr = p.pendingRedaction {
            let r = CGRect(x: pr.minX * size.width, y: pr.minY * size.height, width: pr.width * size.width, height: pr.height * size.height)
            ctx.setFillColor(pink.withAlpha(0.2).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(pink.cgColor)
            ctx.setLineWidth(max(1, 2 * unit))
            ctx.stroke(r)
        }
        return ctx.makeImage() ?? image
    }
}
