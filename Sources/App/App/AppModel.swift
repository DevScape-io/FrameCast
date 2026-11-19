import SwiftUI
import AVFoundation
import Combine
import Carbon.HIToolbox

struct CaptureDeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

enum SpecSource {
    case none, usb, resolution, manual
    var label: String {
        switch self {
        case .none: return "no device"
        case .usb: return "read over USB"
        case .resolution: return "matched by resolution"
        case .manual: return "chosen manually"
        }
    }
}

/// Coordinates capture, rendering, outputs and UI state.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings.shared
    let profiles = ProfileStore()
    let frames = FrameLibrary()
    let presenter = PresenterModel()
    let vcamInstaller = VirtualCameraInstaller()
    let renderLoop = RenderLoop()
    private let capture = CaptureController()
    private let vcamSink = VirtualCameraSink()

    @Published private(set) var devices: [CaptureDeviceInfo] = []
    @Published var selectedDeviceID: String? {
        didSet { if oldValue != selectedDeviceID { connectSelectedDevice() } }
    }
    @Published private(set) var identity: DeviceIdentity?
    @Published private(set) var contentSize: CGSize?
    /// "auto", "none", "builtin:<specID>" or "imported:<uuid>"
    @Published var frameSelection = "auto" {
        didSet {
            guard oldValue != frameSelection else { return }
            if let id = selectedDeviceID { settings.frameOverrides[id] = frameSelection }
            pushRenderConfig()
        }
    }
    @Published private(set) var resolvedSpec: DeviceSpec = DeviceCatalog.genericIPad
    @Published private(set) var specSource: SpecSource = .none
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var countdown: Int?
    @Published private(set) var virtualCameraOn = false
    @Published private(set) var canvasSize: CGSize = .zero
    @Published var alwaysOnTop = false
    @Published var showInspector = true
    /// The one-time "Enjoying FrameCast?" prompt is due.
    @Published var showSupportNudge = false
    /// When true the live output lives in its own window and the main window holds only the controls.
    @Published var outputDetached = UserDefaults.standard.bool(forKey: "outputDetached") {
        didSet {
            guard !isTerminating, oldValue != outputDetached else { return }
            UserDefaults.standard.set(outputDetached, forKey: "outputDetached")
            guard bootstrapped else { return }
            if outputDetached { outputWindow.show() } else { outputWindow.close() }
        }
    }
    /// The detached output window (canvas or frame-only), created on first use.
    private(set) lazy var outputWindow = OutputWindowController(model: self)
    /// Set while the app quits so windows closing on the way out don't reset `outputDetached`.
    private(set) var isTerminating = false

    /// Guidance for the presenter, shown beside the output rather than on it.
    var presenterHint: String? {
        if let countdown { return "Recording starts in \(countdown)…" }
        if presenter.tool == .redact { return "Drag on the device to redact · Right-click a box to remove it" }
        return nil
    }

    /// Brings up the detached output window, detaching the preview if needed.
    func showOutputWindow() {
        if outputDetached { outputWindow.show() } else { outputDetached = true }
    }

    /// The user closed the output window: put the preview back in the main window.
    func outputWindowDidClose() {
        if !isTerminating, outputDetached { outputDetached = false }
    }
    /// Transient message; clears itself after a few seconds.
    @Published var banner: String? {
        didSet {
            guard let message = banner, message != oldValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.banner == message else { return }
                withAnimation { self.banner = nil }
            }
        }
    }
    @Published private(set) var flashToken = 0

    private var avDevices: [String: AVCaptureDevice] = [:]
    private var recorder: Recorder?
    private var countdownTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var bootstrapped = false
    private var hotKeysRegistered: Bool?
    private var appliedWebcam: String?

    // MARK: - Lifecycle

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        ScreenCaptureDevices.enable()

        let loop = renderLoop
        capture.onVideoFrame = { @Sendable pb in loop.updateDeviceBuffer(pb) }
        capture.onDeviceAudio = { @Sendable sb in loop.appendDeviceAudio(sb) }
        capture.onMicAudio = { @Sendable sb in loop.appendMicAudio(sb) }
        capture.onWebcamFrame = { @Sendable pb in loop.updateWebcamBuffer(pb) }
        renderLoop.setContentSizeHandler { [weak self] size in
            MainActor.assumeIsolated { self?.contentSizeChanged(size) }
        }

        // Re-render config whenever settings, profiles or frames change.
        settings.objectWillChange.merge(with: profiles.objectWillChange, frames.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        presenter.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncPresenterOptions() }
            .store(in: &cancellables)

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isTerminating = true }
        })
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }

        if SupportUs.registerLaunchAndCheck() {
            // Give the window a moment to settle; the prompt shouldn't be the first thing seen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                withAnimation { self?.showSupportNudge = true }
            }
        }

        renderLoop.start(fps: settings.frameRate)
        pushRenderConfig()
        if outputDetached { outputWindow.show() }
        syncPresenterOptions()
        applyAudioSettings()
        applyWebcamSettings()
        registerHotKeys()
        vcamInstaller.refreshStatus()

        // Start feeding the virtual camera at launch if it's installed (unless it was switched
        // off), and as soon as it finishes installing.
        if settings.virtualCameraWanted { setVirtualCamera(true, quiet: true) }
        vcamInstaller.$isInstalled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] installed in
                guard let self, installed, self.settings.virtualCameraWanted, !self.virtualCameraOn else { return }
                self.setVirtualCamera(true, quiet: true)
            }
            .store(in: &cancellables)

        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                if !granted {
                    self.banner = "FrameCast needs Camera access to capture devices. Enable it in System Settings › Privacy & Security › Camera."
                }
                self.refreshDevices()
            }
        }
        // iOS devices can take a few seconds to appear after enabling screen-capture devices.
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.refreshDevices() }
            }
        }
    }

    // MARK: - Devices

    func refreshDevices() {
        let list = ScreenCaptureDevices.discover()
        var map: [String: AVCaptureDevice] = [:]
        for d in list { map[d.uniqueID] = d }
        avDevices = map
        devices = list.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }

        if let selected = selectedDeviceID, map[selected] == nil {
            if isRecording { stopRecording() }
            selectedDeviceID = nil
        }
        if selectedDeviceID == nil, let first = devices.first {
            selectedDeviceID = first.id
        }
    }

    var selectedDeviceName: String? {
        devices.first { $0.id == selectedDeviceID }?.name
    }

    private func connectSelectedDevice() {
        identity = nil
        guard let id = selectedDeviceID, let device = avDevices[id] else {
            capture.stop()
            renderLoop.updateDeviceBuffer(nil)
            pushRenderConfig()
            return
        }
        frameSelection = settings.frameOverrides[id] ?? settings.defaultFrameID
        capture.start(device: device) { @Sendable error in
            guard let message = error?.localizedDescription else { return }
            Task { @MainActor in self.banner = "Couldn’t start capture: \(message)" }
        }
        identify(device)
        pushRenderConfig()
    }

    private func identify(_ device: AVCaptureDevice) {
        let uid = device.uniqueID, name = device.localizedName, dir = settings.libimobiledeviceDir
        Task.detached(priority: .utility) {
            let result = DeviceIdentifier.identify(captureUniqueID: uid, captureName: name, customDir: dir)
            await self.applyIdentity(result, for: uid)
        }
    }

    private func applyIdentity(_ result: DeviceIdentity?, for uid: String) {
        guard selectedDeviceID == uid else { return }
        identity = result
        pushRenderConfig()
    }

    func reidentify() {
        if let id = selectedDeviceID, let device = avDevices[id] { identify(device) }
    }

    private func contentSizeChanged(_ size: CGSize?) {
        contentSize = size
        pushRenderConfig()
    }

    // MARK: - Render configuration

    private func settingsChanged() {
        pushRenderConfig()
        applyAudioSettings()
        applyWebcamSettings()
        renderLoop.start(fps: settings.frameRate)
        if hotKeysRegistered != settings.globalHotKeys { registerHotKeys() }
    }

    private func resolveFrame() -> (DeviceSpec, SpecSource, FrameSource) {
        let landscape = (contentSize?.width ?? 0) > (contentSize?.height ?? 1)
        var spec = DeviceCatalog.genericIPad
        var source = SpecSource.none
        if let pt = identity?.productType, let s = DeviceCatalog.spec(productType: pt) {
            spec = s; source = .usb
        } else if let size = contentSize {
            spec = DeviceCatalog.bestMatch(size: size); source = .resolution
        }
        let color = settings.frameColor
        let selection = frameSelection

        if selection == "none" { return (spec, source, .none) }
        if selection.hasPrefix("builtin:"), let s = DeviceCatalog.spec(id: String(selection.dropFirst("builtin:".count))) {
            return (s, .manual, .procedural(color))
        }
        if selection.hasPrefix("imported:"),
           let uuid = UUID(uuidString: String(selection.dropFirst("imported:".count))),
           let frame = frames.frame(id: uuid), let asset = frames.asset(for: frame) {
            let alt = frames.alternate(for: frame).flatMap { frames.asset(for: $0) }
            if let linked = frame.linkedSpecID.flatMap({ DeviceCatalog.spec(id: $0) }) {
                return (linked, .manual, .image(primary: asset, alternate: alt))
            }
            return (spec, source, .image(primary: asset, alternate: alt))
        }
        // Auto: prefer an imported frame linked to this model, else the built-in frame.
        if let frame = frames.preferred(forSpec: spec.id, landscape: landscape), let asset = frames.asset(for: frame) {
            let alt = frames.alternate(for: frame).flatMap { frames.asset(for: $0) }
            return (spec, source, .image(primary: asset, alternate: alt))
        }
        return (spec, source, .procedural(color))
    }

    func pushRenderConfig() {
        let (spec, source, frame) = resolveFrame()
        if resolvedSpec != spec { resolvedSpec = spec }
        specSource = selectedDeviceID == nil ? .none : source

        var c = RenderConfig()
        c.profile = profiles.selected
        c.spec = spec
        c.frame = frame
        c.tokens = tokenContext()
        c.canvasPreset = settings.canvasPreset
        c.maxAutoSide = settings.videoCodec == .h264 ? 2560 : 3840
        c.overlaysInRecordings = settings.overlaysInRecordings
        c.overlaysInScreenshots = settings.overlaysInScreenshots
        c.overlaysInVirtualCamera = settings.overlaysInVirtualCamera
        c.annotationFade = settings.annotationFadeSeconds
        renderLoop.setConfig(c)
    }

    private func tokenContext() -> TokenContext {
        TokenContext(deviceName: selectedDeviceName ?? "No device",
                     modelName: resolvedSpec.name,
                     company: settings.companyName,
                     profileName: profiles.selected.name)
    }

    private func syncPresenterOptions() {
        let tool = presenter.tool, highlight = presenter.highlightCursor
        renderLoop.mutatePresenter { p in
            p.tool = tool
            p.highlightCursor = highlight
            if tool != .redact { p.pendingRedaction = nil }
        }
    }

    func updateCanvasSize(_ size: CGSize) {
        if canvasSize != size { canvasSize = size }
    }

    // MARK: - Frame labels

    var frameMenuLabel: String {
        switch frameSelection {
        case "auto": return "Auto: \(resolvedSpec.name)"
        case "none": return "No Frame"
        default:
            if frameSelection.hasPrefix("imported:"),
               let uuid = UUID(uuidString: String(frameSelection.dropFirst("imported:".count))),
               let f = frames.frame(id: uuid) { return f.name }
            return resolvedSpec.name
        }
    }

    // MARK: - Redactions & drawings

    func addRedaction(_ rect: CGRect) {
        var p = profiles.selected
        p.redactions.append(Redaction(rect: rect))
        profiles.selected = p
    }

    func removeRedaction(id: UUID) {
        var p = profiles.selected
        p.redactions.removeAll { $0.id == id }
        profiles.selected = p
    }

    func clearAnnotations() {
        renderLoop.mutatePresenter { $0.strokes.removeAll() }
    }

    // MARK: - Audio

    /// Runs the presenter webcam only while the selected profile shows it.
    private func applyWebcamSettings() {
        let wanted = profiles.selected.webcam.enabled
        let key = wanted ? "on:\(settings.webcamID)" : "off"
        guard key != appliedWebcam else { return }
        appliedWebcam = key
        guard wanted else {
            capture.setWebcam(enabled: false, uniqueID: "")
            return
        }
        let id = settings.webcamID
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            capture.setWebcam(enabled: true, uniqueID: id)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in
                    if ok { self.capture.setWebcam(enabled: true, uniqueID: id) }
                    else { self.banner = "Camera access was denied." }
                }
            }
        default:
            banner = "Camera access is off. Enable it in System Settings › Privacy & Security › Camera."
        }
    }

    private func applyAudioSettings() {
        capture.setMonitor(enabled: settings.playDeviceAudio, volume: Float(settings.monitorVolume))
        if settings.recordMicrophone {
            let id = settings.microphoneID
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                capture.setMicrophone(enabled: true, uniqueID: id)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    Task { @MainActor in
                        if ok { self.capture.setMicrophone(enabled: true, uniqueID: id) }
                        else { self.banner = "Microphone access was denied." }
                    }
                }
            default:
                banner = "Microphone access is off. Enable it in System Settings › Privacy & Security › Microphone."
            }
        } else {
            capture.setMicrophone(enabled: false, uniqueID: "")
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording || countdown != nil { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard selectedDeviceID != nil else {
            banner = "Connect a device before recording."
            return
        }
        let seconds = settings.countdownSeconds
        guard seconds > 0 else { beginRecording(); return }
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            for i in stride(from: seconds, to: 0, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.setCountdown(i)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.setCountdown(nil)
            self.beginRecording()
        }
    }

    private func setCountdown(_ value: Int?) {
        countdown = value
        renderLoop.mutatePresenter { $0.countdown = value }
    }

    private func beginRecording() {
        let size = renderLoop.currentCanvasSize()
        let codec = settings.videoCodec
        let container: ContainerFormat = codec == .proRes422 ? .mov : settings.container
        let url = OutputNaming.url(folder: settings.recordingsFolder, pattern: settings.fileNamePattern,
                                   tokens: tokenContext(), ext: container.fileExtension)
        do {
            let rec = try Recorder(url: url, size: size, fps: settings.frameRate, codec: codec,
                                   fileType: container.fileType,
                                   deviceAudio: settings.recordDeviceAudio ? (capture.deviceAudioHint ?? .fallback) : nil,
                                   mic: settings.recordMicrophone ? (capture.micHint ?? .fallback) : nil)
            recorder = rec
            renderLoop.setRecorder(rec)
            isRecording = true
            recordingStartedAt = Date()
        } catch {
            banner = "Couldn’t start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        if countdown != nil {
            countdownTask?.cancel()
            countdownTask = nil
            setCountdown(nil)
            return
        }
        guard let rec = recorder else { return }
        renderLoop.setRecorder(nil)
        recorder = nil
        isRecording = false
        recordingStartedAt = nil
        let openTrimmer = settings.openTrimmerAfterRecording
        rec.finish { @Sendable url, error in
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let url {
                        self.banner = "Saved \(url.lastPathComponent)"
                        if openTrimmer { TrimWindowController.present(url: url) }
                    } else {
                        self.banner = "Recording failed: \(message ?? "unknown error")"
                    }
                }
            }
        }
    }

    func revealRecordings() {
        let url = URL(fileURLWithPath: (settings.recordingsFolder as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Screenshots

    func takeScreenshot() {
        let include = settings.overlaysInScreenshots
        let copy = settings.copyScreenshotsToClipboard
        let url = OutputNaming.url(folder: settings.screenshotsFolder, pattern: settings.fileNamePattern,
                                   tokens: tokenContext(), ext: "png")
        renderLoop.requestScreenshot(includeOverlays: include) { image in
            MainActor.assumeIsolated {
                guard let image else { return }
                self.flashToken += 1
                if copy { ScreenshotWriter.copyToClipboard(image) }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try ScreenshotWriter.savePNG(image, to: url) }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            switch result {
                            case .success: self.banner = "Screenshot saved\(copy ? " and copied" : "") — \(url.lastPathComponent)"
                            case .failure(let e): self.banner = "Couldn’t save screenshot: \(e.localizedDescription)"
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Virtual camera

    /// `quiet` is for automatic attempts (launch, after install): no banner if it isn't there yet.
    func setVirtualCamera(_ on: Bool, quiet: Bool = false) {
        if !quiet { settings.virtualCameraWanted = on }
        if on {
            if vcamSink.connect() {
                renderLoop.setVirtualCamera(vcamSink)
                virtualCameraOn = true
            } else {
                virtualCameraOn = false
                guard !quiet else { return }
                vcamInstaller.refreshStatus()
                banner = vcamInstaller.isInstalled
                    ? "Couldn’t connect to the virtual camera. Quit the call app and FrameCast, then open FrameCast first."
                    : "The virtual camera isn’t installed yet — open Settings › Virtual Camera."
            }
        } else {
            renderLoop.setVirtualCamera(nil)
            vcamSink.disconnect()
            virtualCameraOn = false
        }
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        GlobalHotKeys.shared.unregisterAll()
        hotKeysRegistered = settings.globalHotKeys
        guard settings.globalHotKeys else { return }
        let mods = cmdKey | optionKey | controlKey
        GlobalHotKeys.shared.register(id: 1, keyCode: kVK_ANSI_S, modifiers: mods) { [weak self] in
            MainActor.assumeIsolated { self?.takeScreenshot() }
        }
        GlobalHotKeys.shared.register(id: 2, keyCode: kVK_ANSI_R, modifiers: mods) { [weak self] in
            MainActor.assumeIsolated { self?.toggleRecording() }
        }
        GlobalHotKeys.shared.register(id: 3, keyCode: kVK_ANSI_K, modifiers: mods) { [weak self] in
            MainActor.assumeIsolated { self?.clearAnnotations() }
        }
        GlobalHotKeys.shared.register(id: 4, keyCode: kVK_ANSI_D, modifiers: mods) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presenter.tool = self.presenter.tool == .pen ? .pointer : .pen
            }
        }
    }
}
