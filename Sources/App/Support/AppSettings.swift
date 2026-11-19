import Foundation
import AVFoundation
import CoreGraphics

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc, h264, proRes422
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hevc: return "HEVC (H.265)"
        case .h264: return "H.264"
        case .proRes422: return "ProRes 422"
        }
    }
    var avCodec: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .h264: return .h264
        case .proRes422: return .proRes422
        }
    }
}

enum ContainerFormat: String, CaseIterable, Identifiable {
    case mov, mp4
    var id: String { rawValue }
    var label: String { self == .mov ? "QuickTime (.mov)" : "MPEG-4 (.mp4)" }
    var fileType: AVFileType { self == .mov ? .mov : .mp4 }
    var fileExtension: String { rawValue }
}

enum CanvasPreset: String, CaseIterable, Identifiable {
    case auto, hd720, hd1080, uhd4k, square1080, vertical1080
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Fit device (native resolution)"
        case .hd720: return "1280 × 720"
        case .hd1080: return "1920 × 1080"
        case .uhd4k: return "3840 × 2160"
        case .square1080: return "1080 × 1080 (square)"
        case .vertical1080: return "1080 × 1920 (vertical)"
        }
    }
    var fixedSize: CGSize? {
        switch self {
        case .auto: return nil
        case .hd720: return CGSize(width: 1280, height: 720)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .uhd4k: return CGSize(width: 3840, height: 2160)
        case .square1080: return CGSize(width: 1080, height: 1080)
        case .vertical1080: return CGSize(width: 1080, height: 1920)
        }
    }
}

enum FrameColor: String, CaseIterable, Identifiable {
    case spaceBlack, silver, blue
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spaceBlack: return "Space Black"
        case .silver: return "Silver"
        case .blue: return "Blue"
        }
    }
    var body: RGBAColor {
        switch self {
        case .spaceBlack: return RGBAColor(0.15, 0.15, 0.16)
        case .silver: return RGBAColor(0.80, 0.81, 0.83)
        case .blue: return RGBAColor(0.30, 0.39, 0.52)
        }
    }
    var rim: RGBAColor {
        switch self {
        case .spaceBlack: return RGBAColor(0.34, 0.34, 0.36)
        case .silver: return RGBAColor(0.93, 0.93, 0.95)
        case .blue: return RGBAColor(0.48, 0.57, 0.70)
        }
    }
    /// Front glass color for older home-button devices.
    var homeFront: RGBAColor {
        self == .silver ? RGBAColor(0.97, 0.97, 0.97) : RGBAColor(0.04, 0.04, 0.05)
    }
}

/// App-wide preferences persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let defaults = UserDefaults.standard
    private static func save(_ value: Any?, _ key: String) { defaults.set(value, forKey: key) }

    // Output
    @Published var recordingsFolder: String { didSet { Self.save(recordingsFolder, "recordingsFolder") } }
    @Published var screenshotsFolder: String { didSet { Self.save(screenshotsFolder, "screenshotsFolder") } }
    @Published var fileNamePattern: String { didSet { Self.save(fileNamePattern, "fileNamePattern") } }
    @Published var companyName: String { didSet { Self.save(companyName, "companyName") } }
    @Published var videoCodec: VideoCodec { didSet { Self.save(videoCodec.rawValue, "videoCodec") } }
    @Published var container: ContainerFormat { didSet { Self.save(container.rawValue, "container") } }
    @Published var frameRate: Int { didSet { Self.save(frameRate, "frameRate") } }
    @Published var canvasPreset: CanvasPreset { didSet { Self.save(canvasPreset.rawValue, "canvasPreset") } }
    @Published var countdownSeconds: Int { didSet { Self.save(countdownSeconds, "countdownSeconds") } }
    @Published var openTrimmerAfterRecording: Bool { didSet { Self.save(openTrimmerAfterRecording, "openTrimmerAfterRecording") } }
    @Published var copyScreenshotsToClipboard: Bool { didSet { Self.save(copyScreenshotsToClipboard, "copyScreenshotsToClipboard") } }
    @Published var outputStyle: OutputStyle { didSet { Self.save(outputStyle.rawValue, "outputStyle") } }

    // Overlays: burn in per output ("toggle per capture")
    @Published var overlaysInRecordings: Bool { didSet { Self.save(overlaysInRecordings, "overlaysInRecordings") } }
    @Published var overlaysInScreenshots: Bool { didSet { Self.save(overlaysInScreenshots, "overlaysInScreenshots") } }
    @Published var overlaysInVirtualCamera: Bool { didSet { Self.save(overlaysInVirtualCamera, "overlaysInVirtualCamera") } }

    // Audio
    @Published var playDeviceAudio: Bool { didSet { Self.save(playDeviceAudio, "playDeviceAudio") } }
    @Published var monitorVolume: Double { didSet { Self.save(monitorVolume, "monitorVolume") } }
    @Published var recordDeviceAudio: Bool { didSet { Self.save(recordDeviceAudio, "recordDeviceAudio") } }
    @Published var recordMicrophone: Bool { didSet { Self.save(recordMicrophone, "recordMicrophone") } }
    @Published var microphoneID: String { didSet { Self.save(microphoneID, "microphoneID") } }

    // Presenter
    @Published var annotationFadeSeconds: Double { didSet { Self.save(annotationFadeSeconds, "annotationFadeSeconds") } }

    // Frames & devices
    @Published var defaultFrameID: String { didSet { Self.save(defaultFrameID, "defaultFrameID") } }
    @Published var frameColor: FrameColor { didSet { Self.save(frameColor.rawValue, "frameColor") } }
    @Published var frameOverrides: [String: String] { didSet { Self.save(frameOverrides, "frameOverrides") } }
    @Published var libimobiledeviceDir: String { didSet { Self.save(libimobiledeviceDir, "libimobiledeviceDir") } }

    // Shortcuts
    @Published var globalHotKeys: Bool { didSet { Self.save(globalHotKeys, "globalHotKeys") } }

    private init() {
        let d = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
        func str(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }

        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]

        recordingsFolder = str("recordingsFolder", movies.appendingPathComponent("FrameCast").path)
        screenshotsFolder = str("screenshotsFolder", pictures.appendingPathComponent("FrameCast").path)
        fileNamePattern = str("fileNamePattern", "{profile} - {device} - {date} {time}")
        companyName = str("companyName", "")
        videoCodec = VideoCodec(rawValue: str("videoCodec", "")) ?? .hevc
        container = ContainerFormat(rawValue: str("container", "")) ?? .mov
        frameRate = int("frameRate", 30)
        canvasPreset = CanvasPreset(rawValue: str("canvasPreset", "")) ?? .auto
        countdownSeconds = int("countdownSeconds", 3)
        openTrimmerAfterRecording = bool("openTrimmerAfterRecording", false)
        copyScreenshotsToClipboard = bool("copyScreenshotsToClipboard", true)
        outputStyle = OutputStyle(rawValue: str("outputStyle", "")) ?? .canvas

        overlaysInRecordings = bool("overlaysInRecordings", true)
        overlaysInScreenshots = bool("overlaysInScreenshots", true)
        overlaysInVirtualCamera = bool("overlaysInVirtualCamera", true)

        playDeviceAudio = bool("playDeviceAudio", true)
        monitorVolume = dbl("monitorVolume", 0.8)
        recordDeviceAudio = bool("recordDeviceAudio", true)
        recordMicrophone = bool("recordMicrophone", false)
        microphoneID = str("microphoneID", "")

        annotationFadeSeconds = dbl("annotationFadeSeconds", 0)

        defaultFrameID = str("defaultFrameID", "auto")
        frameColor = FrameColor(rawValue: str("frameColor", "")) ?? .spaceBlack
        frameOverrides = d.dictionary(forKey: "frameOverrides") as? [String: String] ?? [:]
        libimobiledeviceDir = str("libimobiledeviceDir", "")

        globalHotKeys = bool("globalHotKeys", true)
    }
}
