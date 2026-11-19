import Foundation
import AVFoundation
import CoreMediaIO

/// Exposes iOS devices connected over USB as AVCaptureDevices (the same mechanism QuickTime uses).
enum ScreenCaptureDevices {
    static func enable() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    /// iPhones/iPads show up as external "muxed" (audio + video) devices.
    static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    }

    /// Real cameras for the presenter's picture: built-in, USB and Continuity Camera. Leaves out
    /// iOS screen-capture devices and FrameCast's own virtual camera.
    static func webcams() -> [AVCaptureDevice] {
        let screens = Set(discover().map(\.uniqueID))
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                mediaType: .video, position: .unspecified).devices
            .filter { !screens.contains($0.uniqueID) && $0.localizedName != VirtualCameraSink.deviceName }
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
}

struct AudioFormatHint {
    var sampleRate: Double
    var channels: Int
    static let fallback = AudioFormatHint(sampleRate: 48_000, channels: 2)

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    init?(_ sampleBuffer: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
        sampleRate = asbd.mSampleRate
        channels = Int(asbd.mChannelsPerFrame)
    }
}

enum CaptureError: LocalizedError {
    case cannotAddInput
    var errorDescription: String? { "The device is busy or can't be captured. Close QuickTime or other capture apps and try again." }
}

/// Owns the capture sessions: one for the iOS device (video + device audio), one for the Mac microphone.
final class CaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let micSession = AVCaptureSession()
    private let camSession = AVCaptureSession()
    private let camQueue = DispatchQueue(label: "FrameCast.capture.webcam", qos: .userInitiated)
    private let camOutput = AVCaptureVideoDataOutput()
    private var camInput: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "FrameCast.capture.session")
    private let videoQueue = DispatchQueue(label: "FrameCast.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "FrameCast.capture.audio", qos: .userInitiated)
    private let micQueue = DispatchQueue(label: "FrameCast.capture.mic", qos: .userInitiated)

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let micOutput = AVCaptureAudioDataOutput()
    private let audioPreview = AVCaptureAudioPreviewOutput()

    private var deviceInput: AVCaptureDeviceInput?
    private var micInput: AVCaptureDeviceInput?

    private let hintLock = NSLock()
    private var _deviceAudioHint: AudioFormatHint?
    private var _micHint: AudioFormatHint?

    /// Called on a capture queue.
    var onVideoFrame: ((CVPixelBuffer) -> Void)?
    var onDeviceAudio: ((CMSampleBuffer) -> Void)?
    var onMicAudio: ((CMSampleBuffer) -> Void)?
    /// Presenter webcam frames; nil when the webcam turns off.
    var onWebcamFrame: ((CVPixelBuffer?) -> Void)?

    override init() {
        super.init()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        micOutput.setSampleBufferDelegate(self, queue: micQueue)
        camOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        camOutput.alwaysDiscardsLateVideoFrames = true
        camOutput.setSampleBufferDelegate(self, queue: camQueue)
        audioPreview.volume = 0
    }

    var deviceAudioHint: AudioFormatHint? {
        hintLock.lock(); defer { hintLock.unlock() }
        return _deviceAudioHint
    }

    var micHint: AudioFormatHint? {
        hintLock.lock(); defer { hintLock.unlock() }
        return _micHint
    }

    func start(device: AVCaptureDevice, completion: @escaping (Error?) -> Void) {
        sessionQueue.async {
            self.session.beginConfiguration()
            if let current = self.deviceInput {
                self.session.removeInput(current)
                self.deviceInput = nil
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw CaptureError.cannotAddInput }
                self.session.addInput(input)
                self.deviceInput = input
                for output in [self.videoOutput, self.audioOutput, self.audioPreview] as [AVCaptureOutput]
                where !self.session.outputs.contains(output) && self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                }
                self.session.commitConfiguration()
                if !self.session.isRunning { self.session.startRunning() }
                completion(nil)
            } catch {
                self.session.commitConfiguration()
                completion(error)
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            if let current = self.deviceInput { self.session.removeInput(current) }
            self.deviceInput = nil
            self.session.commitConfiguration()
        }
    }

    /// Plays the device's audio through the Mac's speakers.
    func setMonitor(enabled: Bool, volume: Float) {
        sessionQueue.async {
            self.audioPreview.volume = enabled ? max(0, min(1, volume)) : 0
        }
    }

    func setMicrophone(enabled: Bool, uniqueID: String) {
        sessionQueue.async {
            var wanted: AVCaptureDevice?
            if enabled {
                wanted = uniqueID.isEmpty ? AVCaptureDevice.default(for: .audio)
                    : (AVCaptureDevice(uniqueID: uniqueID) ?? AVCaptureDevice.default(for: .audio))
            }
            let current = self.micInput?.device.uniqueID
            if wanted?.uniqueID == current {
                if wanted != nil && !self.micSession.isRunning { self.micSession.startRunning() }
                return
            }
            self.micSession.beginConfiguration()
            if let input = self.micInput {
                self.micSession.removeInput(input)
                self.micInput = nil
            }
            if let device = wanted, let input = try? AVCaptureDeviceInput(device: device), self.micSession.canAddInput(input) {
                self.micSession.addInput(input)
                self.micInput = input
                if !self.micSession.outputs.contains(self.micOutput), self.micSession.canAddOutput(self.micOutput) {
                    self.micSession.addOutput(self.micOutput)
                }
            }
            self.micSession.commitConfiguration()
            if self.micInput != nil {
                if !self.micSession.isRunning { self.micSession.startRunning() }
            } else if self.micSession.isRunning {
                self.micSession.stopRunning()
            }
        }
    }

    /// Starts, switches or stops the presenter webcam. Safe to call repeatedly with the same values.
    func setWebcam(enabled: Bool, uniqueID: String) {
        sessionQueue.async {
            var wanted: AVCaptureDevice?
            if enabled {
                let cams = ScreenCaptureDevices.webcams()
                wanted = cams.first { $0.uniqueID == uniqueID }
                    ?? AVCaptureDevice.default(for: .video).flatMap { d in cams.first { $0.uniqueID == d.uniqueID } }
                    ?? cams.first
            }
            if wanted?.uniqueID == self.camInput?.device.uniqueID {
                if wanted != nil && !self.camSession.isRunning { self.camSession.startRunning() }
                return
            }
            self.camSession.beginConfiguration()
            if let input = self.camInput {
                self.camSession.removeInput(input)
                self.camInput = nil
            }
            if let device = wanted, let input = try? AVCaptureDeviceInput(device: device), self.camSession.canAddInput(input) {
                // 720p is plenty for a tile and keeps compositing cheap.
                if self.camSession.canSetSessionPreset(.hd1280x720) { self.camSession.sessionPreset = .hd1280x720 }
                self.camSession.addInput(input)
                self.camInput = input
                if !self.camSession.outputs.contains(self.camOutput), self.camSession.canAddOutput(self.camOutput) {
                    self.camSession.addOutput(self.camOutput)
                }
            }
            self.camSession.commitConfiguration()
            if self.camInput != nil {
                if !self.camSession.isRunning { self.camSession.startRunning() }
            } else {
                if self.camSession.isRunning { self.camSession.stopRunning() }
                self.camQueue.async { self.onWebcamFrame?(nil) }
            }
        }
    }

    // MARK: - Sample buffer delegates

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) { onVideoFrame?(pixelBuffer) }
        } else if output === camOutput {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) { onWebcamFrame?(pixelBuffer) }
        } else if output === audioOutput {
            if let hint = AudioFormatHint(sampleBuffer) {
                hintLock.lock(); _deviceAudioHint = hint; hintLock.unlock()
            }
            onDeviceAudio?(Self.toHostTime(sampleBuffer, clock: session.synchronizationClock))
        } else if output === micOutput {
            if let hint = AudioFormatHint(sampleBuffer) {
                hintLock.lock(); _micHint = hint; hintLock.unlock()
            }
            onMicAudio?(Self.toHostTime(sampleBuffer, clock: micSession.synchronizationClock))
        }
    }

    /// Re-times a sample buffer from the session clock to the host clock (the clock our video frames use).
    static func toHostTime(_ sampleBuffer: CMSampleBuffer, clock: CMClock?) -> CMSampleBuffer {
        let host = CMClockGetHostTimeClock()
        guard let clock, !CFEqual(clock, host) else { return sampleBuffer }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let offset = CMTimeSubtract(CMSyncConvertTime(pts, from: clock, to: host), pts)

        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sampleBuffer }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in infos.indices {
            infos[i].presentationTimeStamp = CMTimeAdd(infos[i].presentationTimeStamp, offset)
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeAdd(infos[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: count, sampleTimingArray: &infos,
                                              sampleBufferOut: &out)
        return out ?? sampleBuffer
    }
}
