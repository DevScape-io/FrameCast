import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import QuartzCore
import VideoToolbox

/// What a preview shows: the whole branded canvas, or just the framed device on transparency.
enum PreviewKind {
    case canvas
    case deviceOnly
}

/// One frame for a preview. `layout` always describes the full canvas; `crop` is the part of
/// the canvas the image covers (canvas pixels), or nil when the image is the whole canvas.
struct PreviewFrame {
    let image: CGImage
    let layout: CanvasLayout
    let crop: CGRect?
}

/// Drives rendering at a fixed frame rate on its own queue and fans each frame out to
/// the preview, the recorder, screenshot requests and the virtual camera.
final class RenderLoop: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FrameCast.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var fps = 0

    // Shared state (guarded by `lock`)
    private let lock = NSLock()
    private var config = RenderConfig()
    private var presenter = PresenterSnapshot()
    private var latestBuffer: CVPixelBuffer?
    private var latestWebcam: CVPixelBuffer?
    private var reportedSize: CGSize?
    private var recorder: Recorder?
    private var virtualCamera: VirtualCameraSink?
    private var screenshotRequests: [(Bool, (CGImage?) -> Void)] = []
    private var previewHandlers: [UUID: (kind: PreviewKind, handler: (PreviewFrame) -> Void)] = [:]
    private var contentSizeHandler: ((CGSize?) -> Void)?

    // Render-queue-only state
    private let compositor = Compositor()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var imageSource: CVPixelBuffer?
    private var deviceImage: CGImage?
    private var webcamSource: CVPixelBuffer?
    private var pools: [String: CVPixelBufferPool] = [:]

    // MARK: Control (main thread)

    func start(fps newFPS: Int) {
        let f = max(10, min(60, newFPS))
        guard f != fps || timer == nil else { return }
        fps = f
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / f), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Registers a preview sink. Several can be live at once (e.g. the main window and the
    /// detached output window); each gets every rendered frame on the main queue.
    @discardableResult
    func addPreviewHandler(kind: PreviewKind = .canvas, _ handler: @escaping (PreviewFrame) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); previewHandlers[id] = (kind, handler); lock.unlock()
        return id
    }

    func removePreviewHandler(_ id: UUID) {
        lock.lock(); previewHandlers[id] = nil; lock.unlock()
    }

    func setContentSizeHandler(_ handler: ((CGSize?) -> Void)?) {
        lock.lock(); contentSizeHandler = handler; lock.unlock()
    }

    func setConfig(_ c: RenderConfig) {
        lock.lock(); config = c; lock.unlock()
    }

    func mutatePresenter(_ body: (inout PresenterSnapshot) -> Void) {
        lock.lock(); body(&presenter); lock.unlock()
    }

    func presenterSnapshot() -> PresenterSnapshot {
        lock.lock(); defer { lock.unlock() }
        return presenter
    }

    func setRecorder(_ r: Recorder?) {
        lock.lock(); recorder = r; lock.unlock()
    }

    func setVirtualCamera(_ v: VirtualCameraSink?) {
        lock.lock(); virtualCamera = v; lock.unlock()
    }

    func requestScreenshot(includeOverlays: Bool, completion: @escaping (CGImage?) -> Void) {
        lock.lock(); screenshotRequests.append((includeOverlays, completion)); lock.unlock()
    }

    func currentCanvasSize() -> CGSize {
        lock.lock()
        let c = config, s = reportedSize
        lock.unlock()
        return Compositor.canvasSize(content: s, config: c)
    }

    // MARK: Inputs (capture queues)

    func updateDeviceBuffer(_ pb: CVPixelBuffer?) {
        let size = pb.map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
        lock.lock()
        latestBuffer = pb
        let changed = size != reportedSize
        if changed { reportedSize = size }
        let handler = contentSizeHandler
        lock.unlock()
        if changed { DispatchQueue.main.async { handler?(size) } }
    }

    func updateWebcamBuffer(_ pb: CVPixelBuffer?) {
        lock.lock(); latestWebcam = pb; lock.unlock()
    }

    func appendDeviceAudio(_ sb: CMSampleBuffer) {
        lock.lock(); let r = recorder; lock.unlock()
        r?.appendDeviceAudio(sb)
    }

    func appendMicAudio(_ sb: CMSampleBuffer) {
        lock.lock(); let r = recorder; lock.unlock()
        r?.appendMicAudio(sb)
    }

    // MARK: Frame

    private struct Rendered {
        let buffer: CVPixelBuffer
        let image: CGImage?
        let layout: CanvasLayout
    }

    private func tick() {
        let now = CACurrentMediaTime()
        lock.lock()
        let fade = config.annotationFade
        if fade > 0 {
            presenter.strokes.removeAll { s in
                guard let ended = s.endedAt else { return false }
                return now - ended > fade + 0.6
            }
        }
        presenter.clicks.removeAll { now - $0.time > 0.6 }
        let cfg = config, pres = presenter, pb = latestBuffer, cam = latestWebcam
        let rec = recorder, vcam = virtualCamera, previews = Array(previewHandlers.values)
        let shots = screenshotRequests
        screenshotRequests.removeAll()
        lock.unlock()

        autoreleasepool {
            if cam !== webcamSource {
                var img: CGImage?
                if let cam { VTCreateCGImageFromCVPixelBuffer(cam, options: nil, imageOut: &img) }
                compositor.webcamImage = img
                webcamSource = cam
            }
            var device: DeviceInput?
            if let pb {
                if pb !== imageSource {
                    var img: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
                    deviceImage = img
                    imageSource = pb
                }
                if let img = deviceImage { device = DeviceInput(pixelBuffer: pb, image: img) }
            } else {
                imageSource = nil
                deviceImage = nil
            }

            let size = rec?.size ?? Compositor.canvasSize(content: device?.size, config: cfg)
            let date = Date()
            func render(_ size: CGSize, overlays: Bool, image: Bool) -> Rendered? {
                renderBuffer(size: size, device: device, cfg: cfg, pres: pres, overlays: overlays,
                             now: now, date: date, wantImage: image)
            }

            guard let main = render(size, overlays: true, image: true) else { return }

            let canvasPreviews = previews.filter { $0.kind == .canvas }.map(\.handler)
            let devicePreviews = previews.filter { $0.kind == .deviceOnly }.map(\.handler)

            if let img = main.image, !canvasPreviews.isEmpty {
                let shown = Compositor.needsPreviewExtras(pres)
                    ? compositor.previewExtras(on: img, layout: main.layout, config: cfg, presenter: pres)
                    : img
                let frame = PreviewFrame(image: shown, layout: main.layout, crop: nil)
                DispatchQueue.main.async { for preview in canvasPreviews { preview(frame) } }
            }

            if !devicePreviews.isEmpty,
               let frame = renderDeviceOnly(canvas: size, device: device, cfg: cfg, pres: pres, now: now, date: date) {
                DispatchQueue.main.async { for preview in devicePreviews { preview(frame) } }
            }

            if let rec {
                let time = CMClockGetTime(CMClockGetHostTimeClock())
                if cfg.overlaysInRecordings {
                    rec.appendVideo(main.buffer, at: time)
                } else if let clean = render(size, overlays: false, image: false) {
                    rec.appendVideo(clean.buffer, at: time)
                }
            }

            for (overlays, done) in shots {
                let img = overlays ? main.image : render(size, overlays: false, image: true)?.image
                DispatchQueue.main.async { done(img) }
            }

            if let vcam, vcam.isConnected {
                let vsize = VirtualCameraSink.size
                if vsize == size && cfg.overlaysInVirtualCamera {
                    vcam.send(main.buffer)
                } else if let v = render(vsize, overlays: cfg.overlaysInVirtualCamera, image: false) {
                    vcam.send(v.buffer)
                }
            }
        }
    }

    /// The framed device alone on transparency, at roughly the device's native resolution.
    private func renderDeviceOnly(canvas: CGSize, device: DeviceInput?, cfg: RenderConfig, pres: PresenterSnapshot,
                                  now: CFTimeInterval, date: Date) -> PreviewFrame? {
        let (L, _, _) = Compositor.layout(canvas: canvas, content: device?.size, config: cfg)
        let crop = L.deviceRect
        guard crop.width >= 2, crop.height >= 2 else { return nil }
        var k: CGFloat = 1
        if let device, L.screenRect.width > 0 { k = device.size.width / L.screenRect.width }
        k = min(k, 2400 / max(crop.width, crop.height))
        let w = max(2, Int((crop.width * k).rounded())), h = max(2, Int((crop.height * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let layout = compositor.renderDeviceOnly(in: ctx, outputSize: CGSize(width: w, height: h), canvas: canvas,
                                                 device: device, config: cfg, presenter: pres,
                                                 includeOverlays: true, now: now, date: date)
        guard var image = ctx.makeImage() else { return nil }
        if Compositor.needsPreviewExtras(pres) {
            image = compositor.previewExtras(on: image, layout: layout.cropped(to: crop, outputSize: CGSize(width: w, height: h)),
                                             config: cfg, presenter: pres.cropped(to: crop, canvas: canvas))
        }
        return PreviewFrame(image: image, layout: layout, crop: crop)
    }

    private func pool(for size: CGSize) -> CVPixelBufferPool? {
        let key = "\(Int(size.width))x\(Int(size.height))"
        if let p = pools[key] { return p }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        if pools.count > 4 { pools.removeAll() }
        pools[key] = pool
        return pool
    }

    private func renderBuffer(size: CGSize, device: DeviceInput?, cfg: RenderConfig, pres: PresenterSnapshot,
                              overlays: Bool, now: CFTimeInterval, date: Date, wantImage: Bool) -> Rendered? {
        guard size.width >= 2, size.height >= 2, let pool = pool(for: size) else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        guard let buffer = out else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let layout = compositor.render(in: ctx, size: CGSize(width: w, height: h), device: device, config: cfg,
                                       presenter: pres, includeOverlays: overlays, now: now, date: date)
        ctx.flush()

        var image: CGImage?
        if wantImage {
            // Copy the pixels out: the pool will reuse this buffer's memory later.
            let data = Data(bytes: base, count: bytesPerRow * h)
            if let provider = CGDataProvider(data: data as CFData) {
                image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                space: colorSpace,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        }
        return Rendered(buffer: buffer, image: image, layout: layout)
    }
}
