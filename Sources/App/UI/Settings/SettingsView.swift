import SwiftUI
import AVFoundation

/// Settings window. One tab per job, in the order you meet them:
/// where files go → how recordings are made → devices → frame art → virtual camera → shortcuts.
/// Anything that is part of a look (background, branding, redactions) lives in the main
/// window's settings panel with the profile instead, so each option has exactly one home.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettings().tabItem { Label("Recording", systemImage: "record.circle") }
            DeviceSettings().tabItem { Label("Devices", systemImage: "cable.connector") }
            FrameLibraryView().tabItem { Label("Frames", systemImage: "iphone") }
            VirtualCameraSettings().tabItem { Label("Virtual Camera", systemImage: "video") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 640, height: 500)
    }
}

// MARK: - Shared pieces

/// Small grey explanation under a section.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A folder path with Choose and Show in Finder.
private struct FolderRow: View {
    let title: String
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(path)
                Button("Choose…") { if let p = Panels.chooseFolder(current: path) { path = p } }
                Button {
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
    }
}

/// A status line with a colored dot, like System Settings.
private struct StatusRow: View {
    enum Level { case good, neutral, warning }
    let level: Level
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var color: Color {
        switch level {
        case .good: return .green
        case .neutral: return .secondary
        case .warning: return .orange
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                FolderRow(title: "Recordings", path: $settings.recordingsFolder)
                FolderRow(title: "Screenshots", path: $settings.screenshotsFolder)
            } header: {
                Text("Save To")
            }

            Section {
                TextField("File name", text: $settings.fileNamePattern)
                TextField("Company", text: $settings.companyName, prompt: Text("Used for {company}"))
            } header: {
                Text("Naming")
            } footer: {
                Note("Tokens you can use in file names and overlay text: \(Tokens.help)")
            }

            Section {
                Toggle("Copy screenshots to the clipboard", isOn: $settings.copyScreenshotsToClipboard)
            } header: {
                Text("Screenshots")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Recording

struct RecordingSettings: View {
    @EnvironmentObject var settings: AppSettings
    @State private var mics: [AVCaptureDevice] = []

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $settings.videoCodec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                }
                Picker("File type", selection: $settings.container) {
                    ForEach(ContainerFormat.allCases) { Text($0.label).tag($0) }
                }
                .disabled(settings.videoCodec == .proRes422)
                Picker("Frame rate", selection: $settings.frameRate) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Canvas size", selection: $settings.canvasPreset) {
                    ForEach(CanvasPreset.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Video")
            } footer: {
                Note("“Fit device” keeps the device screen at its native resolution (up to 4K; 2560 px for H.264). ProRes is always saved as QuickTime. The canvas size can’t change during a recording.")
            }

            Section {
                Toggle("Record device audio", isOn: $settings.recordDeviceAudio)
                Toggle("Record microphone", isOn: $settings.recordMicrophone)
                Picker("Microphone", selection: $settings.microphoneID) {
                    Text("System default").tag("")
                    ForEach(mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .disabled(!settings.recordMicrophone)
            } header: {
                Text("Audio")
            } footer: {
                Note("Device audio and the microphone are saved as two separate tracks.")
            }

            Section {
                Toggle("Play device audio on this Mac", isOn: $settings.playDeviceAudio)
                LabeledContent("Volume") {
                    Slider(value: $settings.monitorVolume, in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.playDeviceAudio)
            } header: {
                Text("Listening")
            }

            Section {
                Picker("Countdown", selection: $settings.countdownSeconds) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
                Toggle("Open the trim window when a recording ends", isOn: $settings.openTrimmerAfterRecording)
            } header: {
                Text("Start and Finish")
            }
        }
        .formStyle(.grouped)
        .onAppear { mics = ScreenCaptureDevices.microphones() }
    }
}

// MARK: - Devices

struct DeviceSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var frames: FrameLibrary
    @EnvironmentObject var model: AppModel

    var body: some View {
        let detectionAvailable = DeviceIdentifier.isAvailable(customDir: settings.libimobiledeviceDir)
        Form {
            Section {
                Picker("Frame for new devices", selection: $settings.defaultFrameID) {
                    Text("Auto (detect model)").tag("auto")
                    Text("No frame").tag("none")
                    Divider()
                    ForEach(DeviceCatalog.all) { Text($0.name).tag("builtin:\($0.id)") }
                    if !frames.frames.isEmpty {
                        Divider()
                        ForEach(frames.frames) { Text("Imported: \($0.name)").tag("imported:\($0.id.uuidString)") }
                    }
                }
                Picker("Built-in frame color", selection: $settings.frameColor) {
                    ForEach(FrameColor.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Remembered devices") {
                    HStack(spacing: 8) {
                        Text(settings.frameOverrides.isEmpty ? "None" : "\(settings.frameOverrides.count)")
                            .foregroundStyle(.secondary)
                        Button("Forget All") { settings.frameOverrides = [:] }
                            .disabled(settings.frameOverrides.isEmpty)
                    }
                }
            } header: {
                Text("Frames")
            } footer: {
                Note("FrameCast remembers the frame you pick for each device. Forgetting them makes every device use the default again.")
            }

            Section {
                StatusRow(level: detectionAvailable ? .good : .neutral,
                          text: detectionAvailable
                              ? "Exact models are read over USB."
                              : "Models are matched by screen resolution. Install libimobiledevice to read the exact model over USB.")
                if !detectionAvailable {
                    LabeledContent("Install with Homebrew") {
                        Text("brew install libimobiledevice")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                TextField("Tools folder", text: $settings.libimobiledeviceDir, prompt: Text("Found automatically"))
                LabeledContent("Connected device") {
                    Button("Read Model Again") { model.reidentify() }
                }
            } header: {
                Text("Model Detection")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Virtual camera

struct VirtualCameraSettings: View {
    @EnvironmentObject var installer: VirtualCameraInstaller

    var body: some View {
        Form {
            Section {
                StatusRow(level: installer.isInstalled ? .good : (installer.isBundled ? .neutral : .warning),
                          text: installer.status)
                LabeledContent(installer.isInstalled ? "Installed" : "Not installed") {
                    HStack(spacing: 8) {
                        if installer.busy { ProgressView().controlSize(.small) }
                        Button("Check Again") { installer.refreshStatus() }
                        if installer.isInstalled {
                            Button("Uninstall", role: .destructive) { installer.uninstall() }
                                .disabled(installer.busy || !installer.isBundled)
                        } else {
                            Button("Install") { installer.install() }
                                .buttonStyle(.borderedProminent)
                                .disabled(installer.busy || !installer.isBundled)
                        }
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                Note("The virtual camera shows the framed device as a webcam named “\(VirtualCameraSink.deviceName)”. Choose it as the camera in Zoom, Teams, Meet or OBS, then turn on Virtual Camera in FrameCast.")
            }

            Section {
                requirement("FrameCast is in the Applications folder", met: installer.isInApplicationsFolder)
                requirement("This build includes the camera extension", met: installer.isBundled)
                Label("Approve the extension in System Settings › General › Login Items & Extensions when macOS asks.",
                      systemImage: "hand.raised")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Before You Install")
            }
        }
        .formStyle(.grouped)
        .onAppear { installer.refreshStatus() }
    }

    private func requirement(_ text: String, met: Bool) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: met ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(met ? Color.green : Color.orange)
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    @EnvironmentObject var settings: AppSettings

    private static let global: [(String, String)] = [
        ("Start or stop recording", "⌃⌥⌘R"),
        ("Take screenshot", "⌃⌥⌘S"),
        ("Switch pen on or off", "⌃⌥⌘D"),
        ("Clear drawings", "⌃⌥⌘K"),
    ]
    private static let capture: [(String, String)] = [
        ("Start or stop recording", "⇧⌘R"),
        ("Take screenshot", "⇧⌘S"),
    ]
    private static let tools: [(String, String)] = [
        ("Pointer", "⌘1"), ("Pen", "⌘2"), ("Highlighter", "⌘3"),
        ("Spotlight", "⌘4"), ("Zoom Lens", "⌘5"), ("Redact", "⌘6"),
        ("Clear drawings", "⌘K"),
    ]
    private static let windows: [(String, String)] = [
        ("Separate output window", "⌥⌘O"),
        ("Show or hide settings panel", "⌥⌘I"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Use shortcuts while FrameCast is in the background", isOn: $settings.globalHotKeys)
                if settings.globalHotKeys { rows(Self.global) }
            } header: {
                Text("Anywhere")
            }
            Section { rows(Self.capture) } header: { Text("Capture") }
            Section { rows(Self.tools) } header: { Text("Tools") }
            Section { rows(Self.windows) } header: { Text("Windows") }
        }
        .formStyle(.grouped)
    }

    private func rows(_ list: [(String, String)]) -> some View {
        ForEach(list, id: \.0) { title, keys in
            LabeledContent(title) {
                Text(keys)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}
