import SwiftUI
import AppKit

/// The floating glass strip beside the output.
struct OutputControls: View {
    @ObservedObject var chrome: OutputChrome
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var presenter: PresenterModel

    var body: some View {
        // Notices go under the strip, and the panel is anchored by the strip's top edge, so
        // a message appearing never moves the tools. Everything hugs the side facing the output.
        VStack(alignment: chrome.stripOnLeft ? .trailing : .leading, spacing: 8) {
            // One glass shape: the strip, and the settings beside it when open.
            HStack(alignment: .top, spacing: 0) {
                if chrome.stripOnLeft, chrome.isCustomizing { settingsPane; paneDivider }
                strip
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { reportStripHeight(geo.size.height) }
                            .onChange(of: geo.size.height) { _, h in reportStripHeight(h) }
                    })
                if !chrome.stripOnLeft, chrome.isCustomizing { paneDivider; settingsPane }
            }
            .glassPanel(in: RoundedRectangle(cornerRadius: 28, style: .continuous), interactive: true)

            if let hint = model.presenterHint {
                notice(hint)
                    .foregroundStyle(.white)
                    .background(Color.pink.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let banner = model.banner {
                notice(banner)
                    .glassPanel(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture { model.banner = nil }
                    .transition(.opacity)
            }
        }
        .padding(8)
        .fixedSize()
        .animation(.easeInOut(duration: 0.2), value: model.banner)
    }

    /// A short message, as wide as its text needs up to a limit, with even padding all round.
    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func reportStripHeight(_ height: CGFloat) {
        guard abs(chrome.stripHeight - height) > 0.5 else { return }
        DispatchQueue.main.async { chrome.stripHeight = height }
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
            toggleButton(settings.recordMicrophone ? "mic.fill" : "mic.slash", isOn: settings.recordMicrophone,
                         help: "Record microphone narration with the video") {
                settings.recordMicrophone.toggle()
            }
            toggleButton(model.virtualCameraOn ? "video.fill" : "video", isOn: model.virtualCameraOn,
                         help: "Virtual camera — show this in Zoom, Teams, Meet") {
                model.setVirtualCamera(!model.virtualCameraOn)
            }

            separator

            // Canvas / Frame Only and their options live in one popover.
            // Expands this strip sideways into the output settings.
            toggleButton("slider.horizontal.3", isOn: chrome.isCustomizing,
                         help: "Settings: device, frame, canvas, camera, branding") {
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
        OutputSettingsPane(chrome: chrome)
            .environmentObject(model.profiles)
            .environmentObject(model.frames)
            .frame(width: 340, height: chrome.settingsHeight)
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
