import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreText
import IOKit.audio
import os

// The FrameCast virtual camera. FrameCast.app pushes frames into the sink stream;
// they are republished on the source stream that video-call apps read.
// When no frames arrive, a "waiting" placeholder is shown.

private let log = Logger(subsystem: "FrameCast.CameraExtension", category: "camera")

let kFrameRate: Int32 = 30
let kWidth: Int32 = 1920
let kHeight: Int32 = 1080

private let deviceUUID = UUID(uuidString: "6F1C3D0A-5B7E-4C21-9E3A-2D8B6A1F4C55")!
private let sourceStreamUUID = UUID(uuidString: "A3E1B2C4-7D6F-4A18-8B9C-1E2F3A4B5C6D")!
private let sinkStreamUUID = UUID(uuidString: "B4F2C3D5-8E7A-4B29-9CAD-2F3A4B5C6D7E")!

private func hostTimeNanos() -> UInt64 {
    UInt64(max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC)))
}

// MARK: - Device

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: CameraStreamSource!
    private var sinkStream: CameraSinkSource!
    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!
    private let bufferAuxAttributes: NSDictionary = [kCVPixelBufferPoolAllocationThresholdKey: 5]

    // All mutable state below is touched only on `queue`.
    private let queue = DispatchQueue(label: "FrameCast.camera", qos: .userInteractive)
    private var streamingCounter = 0
    private var placeholderTimer: DispatchSourceTimer?
    private var sinkTimer: DispatchSourceTimer?
    private var sinkClient: CMIOExtensionClient?
    private var consuming = false
    private var lastSinkFrame: UInt64 = 0
    private var placeholder: CVPixelBuffer?

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceUUID,
                                     legacyDeviceID: deviceUUID.uuidString, source: self)

        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: kWidth, height: kHeight, extensions: nil,
                                       formatDescriptionOut: &videoDescription)
        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: kWidth,
            kCVPixelBufferHeightKey: kHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &bufferPool)

        let format = CMIOExtensionStreamFormat(formatDescription: videoDescription,
                                               maxFrameDuration: CMTime(value: 1, timescale: kFrameRate),
                                               minFrameDuration: CMTime(value: 1, timescale: kFrameRate),
                                               validFrameDurations: nil)
        sourceStream = CameraStreamSource(localizedName: "FrameCast Video", streamID: sourceStreamUUID,
                                          streamFormat: format, device: device)
        sinkStream = CameraSinkSource(localizedName: "FrameCast Input", streamID: sinkStreamUUID,
                                      streamFormat: format, device: device)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("FrameCast camera: failed to add streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = "FrameCast Camera" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source stream (apps reading the camera)

    func startStreaming() {
        queue.async {
            self.streamingCounter += 1
            guard self.placeholderTimer == nil else { return }
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.sendPlaceholderIfIdle() }
            t.resume()
            self.placeholderTimer = t
        }
    }

    func stopStreaming() {
        queue.async {
            self.streamingCounter = max(0, self.streamingCounter - 1)
            if self.streamingCounter == 0 {
                self.placeholderTimer?.cancel()
                self.placeholderTimer = nil
            }
        }
    }

    private func sendPlaceholderIfIdle() {
        let now = hostTimeNanos()
        guard now &- lastSinkFrame > 500_000_000, let pb = placeholderBuffer() else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: kFrameRate),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil, formatDescription: videoDescription,
                                           sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        if let sampleBuffer {
            sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: now)
        }
    }

    private func placeholderBuffer() -> CVPixelBuffer? {
        if let placeholder { return placeholder }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, bufferPool, bufferAuxAttributes, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(kWidth), height: Int(kHeight),
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: Int(kWidth), height: Int(kHeight)))
            drawCentered(ctx, "FrameCast", size: 84, y: 580, alpha: 0.9)
            drawCentered(ctx, "Open FrameCast and turn on Virtual Camera", size: 36, y: 470, alpha: 0.55)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        placeholder = pb
        return pb
    }

    private func drawCentered(_ ctx: CGContext, _ text: String, size: CGFloat, y: CGFloat, alpha: CGFloat) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: (CGFloat(kWidth) - width) / 2, y: y)
        CTLineDraw(line, ctx)
    }

    // MARK: Sink stream (FrameCast.app writing frames)

    func startSink(client: CMIOExtensionClient?) {
        queue.async {
            self.sinkClient = client
            guard self.sinkTimer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.consume() }
            t.resume()
            self.sinkTimer = t
        }
    }

    func stopSink() {
        queue.async {
            self.sinkTimer?.cancel()
            self.sinkTimer = nil
            self.sinkClient = nil
            self.consuming = false
        }
    }

    private func consume() {
        guard !consuming, let client = sinkClient else { return }
        consuming = true
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequence, _, _, error in
            guard let self else { return }
            self.queue.async {
                self.consuming = false
                if let error { log.debug("consume error: \(error.localizedDescription, privacy: .public)") }
                guard let sampleBuffer else { return }
                let now = hostTimeNanos()
                self.lastSinkFrame = now
                if self.streamingCounter > 0 {
                    self.sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: now)
                }
                self.sinkStream.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
            }
        }
    }
}

// MARK: - Streams

final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: kFrameRate) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        (device.source as? CameraDeviceSource)?.startStreaming()
    }

    func stopStream() throws {
        (device.source as? CameraDeviceSource)?.stopStreaming()
    }
}

final class CameraSinkSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: kFrameRate) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 2 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        (device.source as? CameraDeviceSource)?.startSink(client: client)
    }

    func stopStream() throws {
        (device.source as? CameraDeviceSource)?.stopSink()
    }
}

// MARK: - Provider

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource(localizedName: "FrameCast Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("FrameCast camera: failed to add device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "FrameCast" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
