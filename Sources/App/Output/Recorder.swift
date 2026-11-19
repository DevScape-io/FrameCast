import Foundation
import AVFoundation

enum RecorderError: LocalizedError {
    case cannotAddVideo
    case noFrames
    var errorDescription: String? {
        switch self {
        case .cannotAddVideo: return "The video encoder couldn't be set up for this size/codec. Try H.264 or a smaller canvas."
        case .noFrames: return "No frames were recorded."
        }
    }
}

/// Writes composited frames plus up to two audio tracks (device audio, microphone) with AVAssetWriter.
/// All timestamps are host-clock times.
final class Recorder {
    let url: URL
    let size: CGSize

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let deviceAudioInput: AVAssetWriterInput?
    private let micInput: AVAssetWriterInput?

    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var startTime = CMTime.invalid
    private var lastVideoTime = CMTime.invalid

    init(url: URL, size: CGSize, fps: Int, codec: VideoCodec, fileType: AVFileType,
         deviceAudio: AudioFormatHint?, mic: AudioFormatHint?) throws {
        self.url = url
        self.size = size
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        if codec != .proRes422 {
            let bitsPerPixel = codec == .hevc ? 0.08 : 0.14
            let bitrate = Int(size.width * size.height * CGFloat(fps) * CGFloat(bitsPerPixel))
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(2_000_000, bitrate),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ] as [String: Any]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError.cannotAddVideo }
        writer.add(videoInput)

        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        self.deviceAudioInput = deviceAudio.flatMap { Recorder.makeAudioInput(writer: writer, hint: $0) }
        self.micInput = mic.flatMap { Recorder.makeAudioInput(writer: writer, hint: $0) }
        self.writer = writer
        self.videoInput = videoInput
    }

    private static func makeAudioInput(writer: AVAssetWriter, hint: AudioFormatHint) -> AVAssetWriterInput? {
        let rate = (8_000...48_000).contains(hint.sampleRate) ? hint.sampleRate : 48_000
        let channels = max(1, min(2, hint.channels))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return input
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if !started {
            guard writer.startWriting() else {
                NSLog("FrameCast: writer failed to start: \(String(describing: writer.error))")
                finished = true
                return
            }
            writer.startSession(atSourceTime: time)
            startTime = time
            started = true
        }
        guard writer.status == .writing else { return }
        if lastVideoTime.isValid && CMTimeCompare(time, lastVideoTime) <= 0 { return }
        if videoInput.isReadyForMoreMediaData {
            if adaptor.append(pixelBuffer, withPresentationTime: time) { lastVideoTime = time }
        }
    }

    func appendDeviceAudio(_ sampleBuffer: CMSampleBuffer) { appendAudio(sampleBuffer, to: deviceAudioInput) }
    func appendMicAudio(_ sampleBuffer: CMSampleBuffer) { appendAudio(sampleBuffer, to: micInput) }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input else { return }
        lock.lock(); defer { lock.unlock() }
        guard started, !finished, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(pts, startTime) >= 0 else { return }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func finish(completion: @escaping (URL?, Error?) -> Void) {
        lock.lock()
        let wasStarted = started, already = finished
        finished = true
        lock.unlock()
        guard !already else { completion(nil, writer.error); return }
        guard wasStarted, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
            completion(nil, writer.error ?? RecorderError.noFrames)
            return
        }
        videoInput.markAsFinished()
        deviceAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        let writer = self.writer, url = self.url
        writer.finishWriting {
            completion(writer.status == .completed ? url : nil, writer.error)
        }
    }
}
