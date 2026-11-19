import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var presenter: PresenterModel
    @EnvironmentObject var frames: FrameLibrary

    @State private var windowBox = WindowBox()

    var body: some View {
        Group {
            if model.outputDetached {
                // Output lives in its own window; this one is just the controls.
                VStack(spacing: 0) {
                    SessionCard()
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    InspectorView()
                }
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        PreviewStage()
                        StatusStrip()
                    }
                    if model.showInspector {
                        Divider()
                        InspectorView()
                            .frame(width: 330)
                    }
                }
            }
        }
        .frame(minWidth: model.outputDetached ? 380 : 900, minHeight: 600)
        .overlay(alignment: .bottomLeading) {
            if model.showSupportNudge {
                SupportNudge()
                    .padding(16)
                    .padding(.bottom, 24)   // clear of the status strip
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar { toolbarContent }
        .translucentWindow()
        .background(WindowAccessor { window in
            windowBox.window = window
            window.level = model.alwaysOnTop && !model.outputDetached ? .floating : .normal
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        })
        .onChange(of: model.outputDetached) { _, detached in
            resizeWindow(forDetached: detached)
        }
    }

    /// Narrows the window to a control panel when the output detaches, and widens it again
    /// when the preview comes back.
    private func resizeWindow(forDetached detached: Bool) {
        DispatchQueue.main.async {
            guard let window = windowBox.window else { return }
            var frame = window.frame
            let width: CGFloat = detached ? min(frame.width, 460) : max(frame.width, 1180)
            guard width != frame.width else { return }
            frame.size.width = width
            if let visible = window.screen?.visibleFrame, frame.maxX > visible.maxX {
                frame.origin.x = max(visible.minX, visible.maxX - width)
            }
            window.setFrame(frame, display: true, animate: true)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker("Device", selection: $model.selectedDeviceID) {
                Text("No Device").tag(String?.none)
                ForEach(model.devices) { d in
                    Text(d.name).tag(String?.some(d.id))
                }
            }
            .help("Connected iPhone or iPad")

            frameMenu
        }

        // Present: drawing tools. They move to the output window's strip when it's detached.
        ToolbarItemGroup(placement: .principal) {
            if !model.outputDetached {
                Picker("Tool", selection: $presenter.tool) {
                    ForEach(PresenterTool.allCases) { tool in
                        Image(systemName: tool.symbol).tag(tool).help("\(tool.label) — \(tool.hint)")
                    }
                }
                .pickerStyle(.segmented)

                if presenter.tool == .pen {
                    ColorPicker("Pen color", selection: $presenter.penColor.swiftUIColor, supportsOpacity: false)
                        .labelsHidden()
                }
                Button { model.clearAnnotations() } label: { Label("Clear Drawings", systemImage: "trash") }
                    .help("Clear drawings (⌘K)")
            }
        }

        // Capture. When detached these sit in the session card instead, where there's room for labels.
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.outputDetached {
                MicToggle()
                VirtualCameraToggle()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.outputDetached {
                Button { model.takeScreenshot() } label: { Label("Screenshot", systemImage: "camera.viewfinder") }
                    .help("Screenshot (⇧⌘S, or ⌃⌥⌘S anywhere)")
                RecordButton()
            }
        }

        // Window layout.
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.outputDetached) {
                Label(model.outputDetached ? "Reattach Output" : "Separate Output Window",
                      systemImage: model.outputDetached ? "pip.enter" : "pip.exit")
            }
            .help(model.outputDetached ? "Move the output back into this window (⌥⌘O)"
                                       : "Show the output in its own window (⌥⌘O)")

            if !model.outputDetached {
                Toggle(isOn: $model.showInspector) { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Show or hide the settings panel (⌥⌘I)")
            }
        }
    }

    private var frameMenu: some View {
        Menu {
            frameButton("Auto (detect model)", id: "auto")
            frameButton("No Frame", id: "none")
            Divider()
            Menu("Built-in Frames") {
                ForEach(DeviceCatalog.all) { spec in
                    frameButton(spec.name, id: "builtin:\(spec.id)")
                }
            }
            Menu("Imported Frames") {
                if frames.frames.isEmpty {
                    Text("None yet")
                }
                ForEach(frames.frames) { f in
                    frameButton(f.name, id: "imported:\(f.id.uuidString)")
                }
            }
            Divider()
            Button("Import Frame Image…") {
                for url in Panels.chooseImages(title: "Import device frame (PNG with transparent screen)") {
                    if let f = try? frames.importFrame(from: url) {
                        model.frameSelection = "imported:\(f.id.uuidString)"
                    }
                }
            }
            Button("Read Model Over USB Again") { model.reidentify() }
            Picker("Frame Color", selection: $settings.frameColor) {
                ForEach(FrameColor.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Button("Use This Frame for New Devices") {
                settings.defaultFrameID = model.frameSelection
            }
        } label: {
            Label(model.frameMenuLabel, systemImage: model.resolvedSpec.family == .iPhone ? "iphone" : "ipad")
                .labelStyle(.titleAndIcon)
        }
        .help("Device frame")
    }

    @ViewBuilder
    private func frameButton(_ title: String, id: String) -> some View {
        Button {
            model.frameSelection = id
        } label: {
            if model.frameSelection == id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

struct StatusStrip: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var presenter: PresenterModel

    var body: some View {
        HStack(spacing: 14) {
            if let hint = model.presenterHint {
                Label(hint, systemImage: "info.circle.fill").foregroundStyle(.pink)
            } else if let name = model.selectedDeviceName {
                Label(name, systemImage: "cable.connector")
                Text("\(model.resolvedSpec.name) · \(model.specSource.label)")
                    .foregroundStyle(.secondary)
                if let s = model.contentSize {
                    Text("\(Int(s.width))×\(Int(s.height))").foregroundStyle(.secondary)
                }
            } else {
                Label("No device — connect an iPhone or iPad with USB, unlock it and tap Trust", systemImage: "cable.connector.slash")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.virtualCameraOn {
                Label("Virtual camera live", systemImage: "video.fill").foregroundStyle(.green)
            }
            if model.canvasSize.width > 0 {
                Text("Canvas \(Int(model.canvasSize.width))×\(Int(model.canvasSize.height))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Shared pieces

/// The live canvas with the screenshot flash and status banner on top.
struct PreviewStage: View {
    @EnvironmentObject var model: AppModel
    var bannerTopInset: CGFloat = 12

    @State private var flashOpacity = 0.0

    var body: some View {
        ZStack(alignment: .top) {
            PreviewRepresentable(model: model)
            Color.white.opacity(flashOpacity).allowsHitTesting(false)
            if let banner = model.banner {
                Text(banner)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassPanel(in: Capsule())
                    .padding(.top, bannerTopInset)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.banner = nil }
            }
        }
        .onChange(of: model.flashToken) { _, _ in
            flashOpacity = 0.85
            withAnimation(.easeOut(duration: 0.35)) { flashOpacity = 0 }
        }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
    }
}

/// Start/stop recording, showing the countdown and elapsed time.
struct RecordButton: View {
    @EnvironmentObject var model: AppModel
    /// Icon-only, for the output window's vertical strip.
    var compact = false

    var body: some View {
        Button { model.toggleRecording() } label: {
            if compact {
                compactLabel
            } else if model.isRecording, let start = model.recordingStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Label(Self.elapsed(from: start, to: context.date), systemImage: "stop.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.red)
                        .monospacedDigit()
                }
            } else if let c = model.countdown {
                Label("\(c)…", systemImage: "timer").labelStyle(.titleAndIcon)
            } else {
                Label("Record", systemImage: "record.circle").labelStyle(.titleAndIcon)
            }
        }
        .help("Start/stop recording (⇧⌘R, or ⌃⌥⌘R anywhere)")
    }

    @ViewBuilder
    private var compactLabel: some View {
        VStack(spacing: 1) {
            if model.isRecording, let start = model.recordingStartedAt {
                Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Self.elapsed(from: start, to: context.date))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.red)
                }
            } else if let c = model.countdown {
                Text("\(c)").font(.system(size: 15, weight: .bold).monospacedDigit())
            } else {
                Image(systemName: "record.circle").foregroundStyle(.red)
            }
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Microphone narration on/off.
struct MicToggle: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        Toggle(isOn: $settings.recordMicrophone) {
            Label("Microphone", systemImage: settings.recordMicrophone ? "mic.fill" : "mic.slash")
        }
        .help("Record microphone narration with the video")
    }
}

/// Virtual camera on/off.
struct VirtualCameraToggle: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Toggle(isOn: Binding(get: { model.virtualCameraOn }, set: { model.setVirtualCamera($0) })) {
            Label("Virtual Camera", systemImage: model.virtualCameraOn ? "video.fill" : "video")
        }
        .help("Virtual camera — show the framed device in Zoom, Teams, Meet")
    }
}

/// Top of the control window while the output is in its own window: capture buttons with
/// labels, then where the output is.
struct SessionCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RecordButton()
                Button { model.takeScreenshot() } label: { Label("Screenshot", systemImage: "camera.viewfinder") }
                    .help("Screenshot (⇧⌘S, or ⌃⌥⌘S anywhere)")
                Spacer(minLength: 8)
                MicToggle().labelStyle(.iconOnly)
                VirtualCameraToggle().labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .controlSize(.large)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "pip.exit").foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Show Output") { model.showOutputWindow() }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .glassPanel(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var detail: String {
        var parts: [String] = []
        if let name = model.selectedDeviceName {
            parts.append(name)
            parts.append(model.resolvedSpec.name)
        } else {
            parts.append("No device connected")
        }
        if model.canvasSize.width > 0 {
            parts.append("\(Int(model.canvasSize.width))×\(Int(model.canvasSize.height))")
        }
        if model.virtualCameraOn { parts.append("Virtual camera live") }
        return parts.joined(separator: " · ")
    }
}
