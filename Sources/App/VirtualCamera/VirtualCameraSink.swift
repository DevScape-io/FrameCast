import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

/// Feeds composited frames into the FrameCast camera extension's sink stream,
/// which republishes them as the "FrameCast Camera" webcam.
final class VirtualCameraSink {
    static let deviceName = "FrameCast Camera"
    /// Must match the sink stream's name in the camera extension (CameraProvider.swift).
    static let sinkStreamName = "FrameCast Input"
    static let size = CGSize(width: 1920, height: 1080)

    private let lock = NSLock()
    private var deviceID: CMIOObjectID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return queue != nil
    }

    func connect() -> Bool {
        disconnect()
        guard let device = Self.findDevice() else { return false }
        let streams = Self.streams(of: device)
        // The extension publishes two streams: the one apps read ("FrameCast Video") and the one
        // we write into ("FrameCast Input"). Find ours by name; fall back to its direction, then
        // to its position. Picking the wrong one looks like success but no frames ever arrive,
        // so callers keep seeing the extension's "waiting" card.
        guard let sink = streams.first(where: { Self.name(of: $0) == Self.sinkStreamName })
                ?? streams.first(where: { Self.direction(of: $0) == 0 })
                ?? (streams.count > 1 ? streams[1] : nil)
        else { return false }

        var unmanaged: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanaged)
        guard status == noErr, let q = unmanaged?.takeUnretainedValue() else { return false }
        guard CMIODeviceStartStream(device, sink) == noErr else { return false }

        lock.lock()
        deviceID = device
        streamID = sink
        queue = q
        lock.unlock()
        return true
    }

    func disconnect() {
        lock.lock()
        let wasConnected = queue != nil
        let d = deviceID, s = streamID
        queue = nil
        lock.unlock()
        if wasConnected { CMIODeviceStopStream(d, s) }
    }

    /// `pixelBuffer` must be 1920×1080 BGRA and IOSurface-backed.
    func send(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let q = queue
        lock.unlock()
        guard let q, CMSimpleQueueGetCount(q) < CMSimpleQueueGetCapacity(q) else { return }

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }
        CMSimpleQueueEnqueue(q, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
    }

    // MARK: - CoreMediaIO helpers

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func findDevice() -> CMIOObjectID? {
        allDevices().first { name(of: $0) == deviceName }
    }

    private static func allDevices() -> [CMIOObjectID] {
        var addr = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func name(of object: CMIOObjectID) -> String? {
        var addr = address(CMIOObjectPropertySelector(kCMIOObjectPropertyName))
        var name: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func streams(of device: CMIOObjectID) -> [CMIOStreamID] {
        var addr = address(CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOStreamID](repeating: 0, count: Int(size) / MemoryLayout<CMIOStreamID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    /// CoreMediaIO's convention: 0 = an output stream (the host writes to the device — our sink),
    /// 1 = an input stream (the host reads from the device — the camera feed).
    private static func direction(of stream: CMIOStreamID) -> UInt32? {
        var addr = address(CMIOObjectPropertySelector(kCMIOStreamPropertyDirection))
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
        else { return nil }
        return value
    }
}
