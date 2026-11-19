import SwiftUI
import AppKit

/// First-run walkthrough: a few short pages that name each group of buttons and what it does.
/// Opens once on first launch and any time from Help › Welcome to FrameCast.
struct WelcomeView: View {
    static let windowID = "welcome"
    private static let seenKey = "welcome.seen"

    /// True until the walkthrough has been shown once.
    static var isDue: Bool { !UserDefaults.standard.bool(forKey: seenKey) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: seenKey) }

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var index = 0

    private let pages = WelcomePage.all

    var body: some View {
        let page = pages[index]
        VStack(spacing: 0) {
            // Page (scrolls if a long page doesn't fit, e.g. with larger text sizes)
            ScrollView(.vertical) {
            VStack(spacing: 14) {
                header(page)
                Text(page.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(page.summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(page.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 15))
                                .frame(width: 30, height: 30)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(item.name).fontWeight(.medium)
                                    if let keys = item.keys {
                                        Text(keys)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    }
                                }
                                Text(item.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .id(index)
            .transition(.opacity)

            Divider()

            // Navigation
            HStack {
                Button("Skip") { finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .opacity(isLast ? 0 : 1)
                    .disabled(isLast)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle()
                            .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Page \(index + 1) of \(pages.count)")
                Spacer()
                Button("Back") { go(-1) }
                    .disabled(index == 0)
                Button(isLast ? "Get Started" : "Next") { isLast ? finish() : go(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 600)
        .translucentWindow()
        .onAppear { Self.markSeen() }
    }

    private var isLast: Bool { index == pages.count - 1 }

    @ViewBuilder
    private func header(_ page: WelcomePage) -> some View {
        if page.usesAppIcon {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
        } else {
            Image(systemName: page.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 72, height: 72)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func go(_ step: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            index = min(max(index + step, 0), pages.count - 1)
        }
    }

    private func finish() {
        Self.markSeen()
        dismissWindow(id: Self.windowID)
    }
}

/// One page of the walkthrough.
struct WelcomePage {
    struct Item: Identifiable {
        let symbol: String
        let name: String
        let detail: String
        var keys: String?
        var id: String { name }
    }

    var symbol = ""
    var usesAppIcon = false
    let title: String
    let summary: String
    let items: [Item]

    /// Icons and names here mirror the real controls (PresenterTool, InspectorTab), so the
    /// walkthrough can't drift from what's on screen.
    static var all: [WelcomePage] {
        [
            WelcomePage(
                usesAppIcon: true,
                title: "Welcome to FrameCast",
                summary: "Show your iPhone or iPad inside a device frame, then record it, capture it, or present it live on a call.",
                items: [
                    Item(symbol: "cable.connector", name: "Mirror over USB", detail: "The same connection QuickTime uses. Nothing to install on the device."),
                    Item(symbol: "photo.artframe", name: "Make it look right", detail: "Device frame, background, your webcam, a nameplate and branding."),
                    Item(symbol: "eye.slash", name: "Keep things private", detail: "Redact parts of the screen, clean up the status bar, add a watermark."),
                ]),
            WelcomePage(
                symbol: "cable.connector",
                title: "Connect a device",
                summary: "Plug in an iPhone or iPad with a cable, unlock it, and tap Trust if it asks. It appears on its own.",
                items: [
                    Item(symbol: "chevron.up.chevron.down", name: "Device", detail: "At the left of the toolbar. Choose which connected device to show."),
                    Item(symbol: "iphone", name: "Frame", detail: "Next to it. FrameCast picks the matching frame; use this to choose another, or none."),
                    Item(symbol: "square.and.arrow.down", name: "Your own frames", detail: "Import Apple’s official bezels in Settings › Frames, or drag a folder of them in."),
                ]),
            WelcomePage(
                symbol: "cursorarrow.rays",
                title: "Point things out",
                summary: "The tools in the middle of the toolbar draw on top of the device while you present.",
                items: PresenterTool.allCases.enumerated().map { i, tool in
                    Item(symbol: tool.symbol, name: tool.label, detail: tool.hint, keys: "⌘\(i + 1)")
                } + [Item(symbol: "trash", name: "Clear Drawings", detail: "Removes everything you’ve drawn.", keys: "⌘K")]),
            WelcomePage(
                symbol: "record.circle",
                title: "Capture it",
                summary: "On the right of the toolbar. Recordings and screenshots are saved to the folders in Settings › General.",
                items: [
                    Item(symbol: "record.circle", name: "Record", detail: "Starts after a short countdown. Click again to stop.", keys: "⇧⌘R"),
                    Item(symbol: "camera.viewfinder", name: "Screenshot", detail: "Saves a PNG and copies it to the clipboard.", keys: "⇧⌘S"),
                    Item(symbol: "mic.fill", name: "Microphone", detail: "Adds your narration to recordings as its own audio track."),
                    Item(symbol: "video.fill", name: "Virtual Camera", detail: "Sends the canvas to Zoom, Teams or Meet as a camera called “\(VirtualCameraSink.deviceName)”. Install it once in Settings › Virtual Camera."),
                ]),
            WelcomePage(
                symbol: "slider.horizontal.3",
                title: "Set the look",
                summary: "The panel on the right has a tab for each part of the picture. A profile saves the whole look so you can switch between them.",
                items: InspectorTab.allCases.map { tab in
                    Item(symbol: tab.symbol, name: tab.label, detail: tab.welcomeDetail)
                }),
            WelcomePage(
                symbol: "pip.exit",
                title: "Present from its own window",
                summary: "Move the output into a separate window to share in a call. The main window steps aside, and the controls float beside the output where your audience can’t see them.",
                items: [
                    Item(symbol: "pip.exit", name: "Separate Output Window", detail: "At the right end of the toolbar. Click the matching button on the strip to bring it back.", keys: "⌥⌘O"),
                    Item(symbol: "slider.horizontal.3", name: "Settings", detail: "On the strip. Opens every setting beside the output, including Canvas or Frame Only."),
                    Item(symbol: "ipad.and.iphone", name: "Frame Only", detail: "Just the device floating on your desktop, with no background."),
                    Item(symbol: "pin", name: "Float on Top", detail: "Keeps the output above your other windows."),
                ]),
        ]
    }
}

private extension InspectorTab {
    var welcomeDetail: String {
        switch self {
        case .canvas: return "Canvas size and background."
        case .device: return "Frame color, size on the canvas, a clean status bar, and redactions."
        case .camera: return "Your webcam and a nameplate with your name, title and company."
        case .branding: return "Watermark, header and confidentiality footer."
        case .presenter: return "Cursor highlight and pen options."
        }
    }
}
