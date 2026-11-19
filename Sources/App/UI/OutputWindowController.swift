import AppKit
import SwiftUI
import Combine

/// How the detached output window looks.
enum OutputStyle: String, CaseIterable, Identifiable {
    /// The full branded canvas: background, padding, header and footer.
    case canvas
    /// Just the framed device floating on the desktop, with no window or background.
    case frameOnly

    var id: String { rawValue }
    var label: String { self == .canvas ? "Canvas" : "Frame Only" }
    var symbol: String { self == .canvas ? "photo.artframe" : "ipad.and.iphone" }
}

/// State shared between the output window controller and its SwiftUI controls.
@MainActor
final class OutputChrome: ObservableObject {
    /// True while the customize popover is open, so the controls don't fade out under it.
    @Published var isCustomizing = false
    /// Height of the frame-only window, in points.
    @Published var frameHeight: Double = 640
    @Published var frameHeightRange: ClosedRange<Double> = 200...1200
    /// True when the strip had to go on the left of the output (no room on the right).
    @Published var stripOnLeft = false
    /// Height available to the settings pane when the strip is expanded.
    @Published var settingsHeight: Double = 560
    var setFrameHeight: (Double) -> Void = { _ in }
}

private final class OutputWindow: NSWindow {
    // Borderless windows refuse key status by default; the output needs it for shortcuts.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // Borderless windows have no close button, so ⌘W would just beep.
    override func performClose(_ sender: Any?) { close() }
}

private final class ControlsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the detached output window and the floating controls beside it.
///
/// The controls live in a separate child panel rather than inside the output window, so
/// sharing just the output window in a video call never shows them. The panel is also
/// marked `sharingType = .none`, which hides it from full-screen shares in apps that honor it.
@MainActor
final class OutputWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private let chrome = OutputChrome()

    private var window: OutputWindow?
    private var panel: ControlsPanel?
    private var host: NSHostingController<AnyView>?
    private var style: OutputStyle = .canvas
    private var shownSize = CGSize(width: 3, height: 4)

    private var cancellables = Set<AnyCancellable>()
    private var sizeObservation: NSKeyValueObservation?
    private var hoverTimer: Timer?
    private var lastHover = Date.distantPast
    private var controlsShown = true
    private var isRebuilding = false
    /// Output window frame from before the strip expanded, restored when it collapses.
    private var frameBeforeSettings: NSRect?
    private var isFitting = false

    init(model: AppModel) {
        self.model = model
        super.init()
        chrome.setFrameHeight = { [weak self] h in
            // A manual resize while the settings are open becomes the new size to keep.
            self?.frameBeforeSettings = nil
            self?.setFrameOnlyHeight(CGFloat(h))
        }

        model.settings.$outputStyle
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] newStyle in
                // @Published fires before the property changes, so hop to the next turn.
                DispatchQueue.main.async { self?.rebuild(as: newStyle) }
            }
            .store(in: &cancellables)
        chrome.$isCustomizing
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] on in DispatchQueue.main.async { self?.settingsToggled(on) } }
            .store(in: &cancellables)
        model.$alwaysOnTop
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyLevel() } }
            .store(in: &cancellables)
    }

    // MARK: Showing and hiding

    func show() {
        if window == nil { build(style: model.settings.outputStyle) }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        if let panel, panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        applyLevel()
        positionPanel()
        startHoverTracking()
    }

    func close() {
        window?.close()
    }

    private func rebuild(as newStyle: OutputStyle) {
        guard let old = window, newStyle != style else { return }
        let wasVisible = old.isVisible
        isRebuilding = true
        old.close()
        isRebuilding = false
        build(style: newStyle)
        if wasVisible { show() }
    }

    private func build(style newStyle: OutputStyle) {
        style = newStyle
        let frameOnly = newStyle == .frameOnly

        let mask: NSWindow.StyleMask = frameOnly
            ? [.borderless, .resizable, .miniaturizable]
            : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let w = OutputWindow(contentRect: NSRect(x: 0, y: 0, width: frameOnly ? 440 : 960, height: frameOnly ? 640 : 720),
                             styleMask: mask, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "FrameCast Output"
        w.delegate = self
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.minSize = NSSize(width: 160, height: 160)
        w.collectionBehavior.insert(.fullScreenAuxiliary)
        if !frameOnly {
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
        }

        let preview = PreviewNSView()
        preview.kind = frameOnly ? .deviceOnly : .canvas
        preview.flashesOnScreenshot = true
        preview.onShownSizeChange = { [weak self] size in self?.shownSizeChanged(size) }
        preview.onMagnify = { [weak self] m in self?.magnify(by: m) }
        preview.attach(model: model)

        if frameOnly {
            w.contentView = preview
        } else {
            let effect = NSVisualEffectView()
            effect.blendingMode = .behindWindow
            effect.material = .fullScreenUI
            effect.state = .active
            preview.frame = effect.bounds
            preview.autoresizingMask = [.width, .height]
            effect.addSubview(preview)
            w.contentView = effect
        }

        let name = "FrameCastOutput.\(newStyle.rawValue)"
        if !w.setFrameUsingName(name) { w.center() }
        w.setFrameAutosaveName(name)
        window = w

        buildPanel()
        updateHeightRange()
    }

    private func buildPanel() {
        let p = ControlsPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 60),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.sharingType = .none
        p.collectionBehavior.insert(.fullScreenAuxiliary)

        let root = OutputControls(chrome: chrome)
            .environmentObject(model)
            .environmentObject(model.settings)
            .environmentObject(model.profiles)
            .environmentObject(model.presenter)
        let h = NSHostingController(rootView: AnyView(root))
        h.sizingOptions = [.preferredContentSize]
        p.contentViewController = h
        sizeObservation = h.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.positionPanel() } }
        }
        host = h
        panel = p
        controlsShown = true
        p.alphaValue = 1
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        if !isRebuilding {
            frameBeforeSettings = nil
            chrome.isCustomizing = false
        }
        hoverTimer?.invalidate()
        hoverTimer = nil
        sizeObservation = nil
        if let panel {
            w.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        // Take the preview out of the window so it stops receiving frames right away.
        w.contentView = nil
        window = nil
        panel = nil
        host = nil
        if !isRebuilding { model.outputWindowDidClose() }
    }

    func windowDidResize(_ notification: Notification) {
        positionPanel()
        if let window { chrome.frameHeight = window.frame.height }
    }

    func windowDidMove(_ notification: Notification) {
        positionPanel()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateHeightRange()
        positionPanel()
    }

    // MARK: Geometry

    private func applyLevel() {
        let level: NSWindow.Level = model.alwaysOnTop ? .floating : .normal
        window?.level = level
        panel?.level = level
    }

    /// Fits the window to the shown image's aspect (device rotated, frame or canvas changed).
    private func shownSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, let window else { return }
        shownSize = size
        window.contentAspectRatio = size
        var f = window.frame
        var height = f.height
        var width = height * size.width / size.height
        if let visible = window.screen?.visibleFrame {
            // Leave room beside a wide canvas for the control strip, so it sits next to the
            // output rather than on top of it.
            let reserve: CGFloat = style == .canvas ? 150 : 0
            let k = min(1, (visible.width - reserve) / width, visible.height / height)
            width *= k
            height *= k
        }
        f.origin.x += (f.width - width) / 2
        f.origin.y += f.height - height
        f.size = CGSize(width: width, height: height)
        window.setFrame(f, display: true)
        chrome.frameHeight = height
        positionPanel()
        if style == .frameOnly {
            // The shadow follows the window's alpha; recompute it once the new shape is drawn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.window?.invalidateShadow() }
        }
    }

    private func setFrameOnlyHeight(_ height: CGFloat) {
        guard let window, shownSize.height > 0 else { return }
        let h = min(max(height, CGFloat(chrome.frameHeightRange.lowerBound)), CGFloat(chrome.frameHeightRange.upperBound))
        let w = h * shownSize.width / shownSize.height
        var f = window.frame
        f.origin.x += (f.width - w) / 2
        f.origin.y += f.height - h   // keep the top edge where it is
        f.size = CGSize(width: w, height: h)
        window.setFrame(f, display: true)
        window.invalidateShadow()
    }

    private func magnify(by amount: CGFloat) {
        guard let window else { return }
        setFrameOnlyHeight(window.frame.height * (1 + amount))
    }

    private func updateHeightRange() {
        let maxH = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 1200
        chrome.frameHeightRange = 200...Double(max(300, maxH))
    }

    /// A vertical strip just outside the right edge of the output, vertically centered.
    /// Falls back to the left edge when the screen has no room on the right, and to just
    /// inside the right edge when there's no room on either side.
    private func positionPanel() {
        guard let window, let panel, let host else { return }
        let size = host.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let gap: CGFloat = 10
        if chrome.isCustomizing { makeRoom(for: size, gap: gap) }
        let wf = window.frame
        let visible = window.screen?.visibleFrame ?? .infinite

        var onLeft = false
        var x = wf.maxX + gap
        if x + size.width > visible.maxX {
            if wf.minX - gap - size.width >= visible.minX {
                x = wf.minX - gap - size.width
                onLeft = true
            } else {
                x = wf.maxX - gap - size.width
            }
        }
        var y = wf.midY - size.height / 2
        y = min(max(y, visible.minY), visible.maxY - size.height)

        if chrome.stripOnLeft != onLeft { chrome.stripOnLeft = onLeft }
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    // MARK: Expanded settings

    /// The strip grows sideways to show the output settings. Make room for it beside the
    /// output (shrinking the output if the screen is too small), and put things back after.
    private func settingsToggled(_ on: Bool) {
        updateSettingsHeight()
        if on {
            if frameBeforeSettings == nil { frameBeforeSettings = window?.frame }
        } else if let saved = frameBeforeSettings, let window {
            frameBeforeSettings = nil
            isFitting = true
            window.setFrame(saved, display: true, animate: true)
            isFitting = false
        }
        // The strip's new size arrives after SwiftUI lays out; positionPanel runs then too.
        DispatchQueue.main.async { [weak self] in self?.positionPanel() }
    }

    private func updateSettingsHeight() {
        let visible = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        chrome.settingsHeight = Double(min(620, max(280, visible - 80)))
    }

    /// Shrinks and/or slides the output so it and a panel of `panelSize` fit side by side on screen.
    private func makeRoom(for panelSize: CGSize, gap: CGFloat) {
        guard let window, !isFitting, let visible = window.screen?.visibleFrame else { return }
        let inset: CGFloat = 8
        var f = window.frame
        let maxW = visible.width - panelSize.width - gap - inset * 2
        guard maxW > 200 else { return }
        if f.width > maxW {
            let k = maxW / f.width
            let top = f.maxY
            f.size = CGSize(width: f.width * k, height: f.height * k)
            f.origin.y = top - f.height
        }
        // Slide left only as far as needed for the panel to sit on the right.
        f.origin.x = max(visible.minX + inset, min(f.origin.x, visible.maxX - inset - panelSize.width - gap - f.width))
        guard f != window.frame else { return }
        isFitting = true
        window.setFrame(f, display: true, animate: false)
        isFitting = false
        chrome.frameHeight = f.height
    }

    // MARK: Hover

    /// Shows the controls while the pointer is over the output or the controls, and fades
    /// them out a moment after it leaves.
    private func startHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
    }

    private func updateHover() {
        guard let window, let panel else { return }
        let mouse = NSEvent.mouseLocation
        let zone = window.frame.union(panel.frame).insetBy(dx: -12, dy: -12)
        let busy = chrome.isCustomizing || model.countdown != nil || model.banner != nil
        if zone.contains(mouse) || busy { lastHover = Date() }
        let show = Date().timeIntervalSince(lastHover) < 1.2
        guard show != controlsShown else { return }
        controlsShown = show
        panel.ignoresMouseEvents = !show
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = show ? 1 : 0
        }
    }
}

// MARK: - Controls

/// The floating glass strip beside the output.
private struct OutputControls: View {
    @ObservedObject var chrome: OutputChrome
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var presenter: PresenterModel

    var body: some View {
        // Hug the side that faces the output, so a banner widens the panel away from it.
        VStack(alignment: chrome.stripOnLeft ? .trailing : .leading, spacing: 8) {
            if let banner = model.banner {
                Text(banner)
                    .font(.callout.weight(.medium))
                    .lineLimit(4)
                    .frame(width: 200, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassPanel(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture { model.banner = nil }
                    .transition(.opacity)
            }
            if let hint = model.presenterHint {
                Text(hint)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .frame(width: 200, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.pink.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            // One glass shape: the strip, and the settings beside it when open. The strip
            // stays on the side that faces the output.
            HStack(alignment: .top, spacing: 0) {
                if chrome.stripOnLeft, chrome.isCustomizing { settingsPane; paneDivider }
                strip
                if !chrome.stripOnLeft, chrome.isCustomizing { paneDivider; settingsPane }
            }
            .glassPanel(in: RoundedRectangle(cornerRadius: 28, style: .continuous), interactive: true)
        }
        .padding(8)
        .fixedSize()
        .animation(.easeInOut(duration: 0.2), value: model.banner)
    }

    private var strip: some View {
        VStack(spacing: 6) {
            if settings.outputStyle == .frameOnly {
                // No title bar or background to grab, so give the device a handle.
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 28)
                    .overlay(WindowDragHandle())
                    .help("Drag to move the device")
                separator
            }
            ForEach(PresenterTool.allCases) { tool in
                toggleButton(tool.symbol, isOn: presenter.tool == tool, help: "\(tool.label) — \(tool.hint)") {
                    presenter.tool = tool
                }
                // The pen's color sits right under the pen, not at the end of the tool list.
                if tool == .pen, presenter.tool == .pen {
                    ColorPicker("Pen color", selection: $presenter.penColor.swiftUIColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 32)
                }
            }
            iconButton("trash", help: "Clear drawings (⌘K)") { model.clearAnnotations() }

            separator

            RecordButton(compact: true)
                .buttonStyle(.plain)
            iconButton("camera.viewfinder", help: "Screenshot (⇧⌘S)") { model.takeScreenshot() }

            separator

            // Canvas / Frame Only and their options live in one popover.
            // Expands this strip sideways into the output settings.
            toggleButton("slider.horizontal.3", isOn: chrome.isCustomizing,
                         help: "Output settings: style, background, webcam, nameplate") {
                chrome.isCustomizing.toggle()
            }
            toggleButton(model.alwaysOnTop ? "pin.fill" : "pin", isOn: model.alwaysOnTop,
                         help: "Float on top of other windows") {
                model.alwaysOnTop.toggle()
            }
            iconButton("pip.enter", help: "Move the output back into the main window (⌥⌘O)") {
                model.outputDetached = false
            }
        }
        .font(.system(size: 15))
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
    }

    private var paneDivider: some View {
        Divider().padding(.vertical, 14)
    }

    private var settingsPane: some View {
        ScrollView(.vertical) {
            OutputCustomizeView(chrome: chrome)
                .environmentObject(model.profiles)
        }
        .frame(width: 300, height: chrome.settingsHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var separator: some View {
        Divider().frame(width: 22).padding(.vertical, 2)
    }

    private func toggleButton(_ symbol: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 32, height: 32)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(Circle().fill(isOn ? Color.accentColor : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        toggleButton(symbol, isOn: false, help: help, action: action)
    }
}

/// Output settings shown when the strip is expanded: what the output is, then each thing
/// on the canvas in the order it's layered (background → device → webcam → nameplate).
private struct OutputCustomizeView: View {
    @ObservedObject var chrome: OutputChrome
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var profiles: ProfileStore
    @State private var webcams: [(id: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Output", selection: $settings.outputStyle) {
                ForEach(OutputStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if settings.outputStyle == .canvas {
                canvasGroup
                backgroundGroup
                deviceGroup
                webcamGroup
                nameplateGroup
                Text("Saved in the “\(profiles.selected.name)” profile. These also apply to recordings, screenshots and the virtual camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                frameOnlyGroup
                deviceGroup
            }
        }
        .controlSize(.small)
        .padding(14)
        .onAppear { webcams = ScreenCaptureDevices.webcams().map { ($0.uniqueID, $0.localizedName) } }
    }

    // MARK: Groups

    private var canvasGroup: some View {
        SettingsGroup("Canvas") {
            Picker("Size", selection: $settings.canvasPreset) {
                ForEach(CanvasPreset.allCases) { Text($0.label).tag($0) }
            }
            labeledSlider("Padding", value: profiles.selectedBinding.background.padding, in: 0...0.25, format: "%.0f%%", scale: 100)
        }
    }

    private var backgroundGroup: some View {
        let bg = profiles.selectedBinding.background
        return SettingsGroup("Background") {
            Picker("Style", selection: bg.style) {
                ForEach(BackgroundStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                ColorPicker(bg.wrappedValue.style == .gradient ? "From" : "Color",
                            selection: bg.color1.swiftUIColor, supportsOpacity: false)
                if bg.wrappedValue.style == .gradient {
                    Spacer()
                    ColorPicker("To", selection: bg.color2.swiftUIColor, supportsOpacity: false)
                }
            }
            if bg.wrappedValue.style == .image {
                HStack {
                    AssetThumbnail(fileName: bg.wrappedValue.imageFile)
                    Button("Choose Image…") {
                        if let f = Panels.importAsset(title: "Background image") { bg.wrappedValue.imageFile = f }
                    }
                    if bg.wrappedValue.imageFile != nil {
                        Button("Remove") { bg.wrappedValue.imageFile = nil }
                    }
                }
            }
        }
    }

    private var deviceGroup: some View {
        SettingsGroup("Device") {
            Picker("Frame color", selection: $settings.frameColor) {
                ForEach(FrameColor.allCases) { Text($0.label).tag($0) }
            }
        }
    }

    private var webcamGroup: some View {
        let cam = profiles.selectedBinding.webcam
        return SettingsGroup("Webcam", isOn: cam.enabled) {
            Picker("Camera", selection: $settings.webcamID) {
                Text("System default").tag("")
                ForEach(webcams, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Layout", selection: cam.layout) {
                ForEach(WebcamLayout.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if cam.wrappedValue.layout == .corner {
                LabeledContent("Position") { CornerPicker(selection: cam.corner) }
            } else {
                Picker("Side", selection: cam.side) {
                    ForEach(CanvasSide.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            labeledSlider("Size", value: cam.size, in: cam.wrappedValue.layout == .corner ? 0.08...0.4 : 0.15...0.45,
                          format: "%.0f%%", scale: 100)
            Picker("Shape", selection: cam.shape) {
                ForEach(WebcamShape.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Mirror", isOn: cam.mirrored)
            BorderRow(isOn: cam.border, color: cam.borderColor)
        }
    }

    private var nameplateGroup: some View {
        let plate = profiles.selectedBinding.nameplate
        return SettingsGroup("Nameplate", isOn: plate.enabled) {
            TextField("Name", text: plate.name, prompt: Text("Name"))
            TextField("Title", text: plate.title, prompt: Text("Title (optional)"))
            TextField("Company", text: plate.company, prompt: Text("Company (optional)"))
            HStack {
                AssetThumbnail(fileName: plate.wrappedValue.logoFile)
                Button("Choose Icon…") {
                    if let f = Panels.importAsset(title: "Nameplate icon (PNG)") { plate.wrappedValue.logoFile = f }
                }
                if plate.wrappedValue.logoFile != nil {
                    Button("Remove") { plate.wrappedValue.logoFile = nil }
                }
            }
            NameplatePlacementRows(plate: plate, webcam: profiles.selected.webcam)
            labeledSlider("Size", value: plate.scale, in: 0.5...2.5, format: "%.0f%%", scale: 100)
            BorderRow(isOn: plate.border, color: plate.borderColor)
            HStack {
                ColorPicker("Card", selection: plate.background.swiftUIColor)
                Spacer()
                ColorPicker("Text", selection: plate.textColor.swiftUIColor, supportsOpacity: false)
            }
        }
    }

    private var frameOnlyGroup: some View {
        SettingsGroup("Floating Device") {
            labeledSlider("Size", value: Binding(get: { chrome.frameHeight }, set: { chrome.setFrameHeight($0) }),
                          in: chrome.frameHeightRange, format: "%.0f pt", scale: 1)
            Text("Drag the handle or the bezel to move it; pinch to resize. The webcam and nameplate are part of the canvas, so they aren’t shown here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                               format: String, scale: Double) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue * scale))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

/// A titled card of related settings. With `isOn`, the title is a switch and the contents
/// only show while it's on.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var isOn: Binding<Bool>?
    @ViewBuilder var content: Content

    init(_ title: String, isOn: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isOn = isOn
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let isOn {
                Toggle(isOn: isOn) { Text(title).font(.subheadline.weight(.semibold)) }
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(title).font(.subheadline.weight(.semibold))
            }
            if isOn?.wrappedValue ?? true { content }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Drag handle

/// Drags the output window (this panel's parent) around the screen. The panel is a child
/// window, so it follows along.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ nsView: DragHandleView, context: Context) {}
}

private final class DragHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // The panel never becomes key, so cursor rects wouldn't apply; use a tracking area.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window, let target = panel.parent else { return }
        let start = NSEvent.mouseLocation
        let origin = target.frame.origin
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let e = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type == .leftMouseDragged {
            let p = NSEvent.mouseLocation
            target.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
        }
    }
}
