import Foundation
import CoreGraphics

enum HAlign: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum WatermarkScope: String, Codable, CaseIterable, Identifiable {
    case canvas, device
    var id: String { rawValue }
    var label: String { self == .canvas ? "Whole canvas" : "Device screen only" }
}

enum RedactionStyle: String, Codable, CaseIterable, Identifiable {
    case blur, pixelate, solid
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case solid, gradient, image
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct WatermarkSettings: Codable, Equatable {
    var enabled = false
    var text = "CONFIDENTIAL · {user} · {date}"
    var useImage = false
    var imageFile: String?
    var tiled = true
    var opacity = 0.12
    var angle = -30.0
    /// Point size at a 1080-pixel-tall canvas; scales with the canvas.
    var fontSize = 30.0
    /// Image watermark width as a fraction of the area width.
    var imageWidth = 0.18
    var spacing = 1.0
    var color = RGBAColor.white
    var scope = WatermarkScope.canvas
}

struct HeaderSettings: Codable, Equatable {
    var enabled = false
    var logoFile: String?
    var title = "{company}"
    var rightText = "{date}"
    var alignment = HAlign.left
    /// Band height as a fraction of canvas height.
    var height = 0.07
    var textColor = RGBAColor.white
    var showDivider = true
}

struct FooterSettings: Codable, Equatable {
    var enabled = false
    var badge = "CONFIDENTIAL"
    var badgeColor = RGBAColor.red
    var text = "Internal use only. Do not share or distribute. Recorded by {fullname}, {datetime}."
    var alignment = HAlign.center
    var height = 0.045
    var textColor = RGBAColor(1, 1, 1, 0.8)
    var showDivider = false
}

struct Redaction: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Normalized to the device screen, top-left origin — follows the device when the layout changes.
    var rect: CGRect
    var style = RedactionStyle.blur
    var color = RGBAColor.black
}

struct StatusBarSettings: Codable, Equatable {
    var enabled = false
    var time = "9:41"
    var iPadDate = "Tue Jan 9"
    var showCellular = true
    var autoColor = true
    var background = RGBAColor.white
    var foreground = RGBAColor.black
}

struct BackgroundSettings: Codable, Equatable {
    var style = BackgroundStyle.gradient
    var color1 = RGBAColor(0.15, 0.16, 0.19)
    var color2 = RGBAColor(0.05, 0.05, 0.07)
    var imageFile: String?
    /// Margin around the device as a fraction of the canvas's short side.
    var padding = 0.05
}

enum CanvasCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

enum CanvasSide: String, Codable, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum WebcamLayout: String, Codable, CaseIterable, Identifiable {
    /// A small picture-in-picture tile in one corner of the canvas.
    case corner
    /// The webcam gets its own column; the device shifts to the other side.
    case side
    var id: String { rawValue }
    var label: String { self == .corner ? "Corner" : "Side by Side" }
}

enum WebcamShape: String, Codable, CaseIterable, Identifiable {
    case circle, rounded
    var id: String { rawValue }
    var label: String { self == .circle ? "Circle" : "Rounded" }
}

/// The presenter's own camera, drawn on the canvas.
struct WebcamSettings: Codable, Equatable {
    var enabled = false
    var layout = WebcamLayout.corner
    var corner = CanvasCorner.bottomRight
    /// Which side the webcam column sits on in the side-by-side layout.
    var side = CanvasSide.right
    /// Tile width as a fraction of the canvas width.
    var size = 0.22
    var shape = WebcamShape.circle
    var mirrored = true
    var border = true
    // Optional so profiles saved before this existed still load.
    private var borderColorStore: RGBAColor?
    var borderColor: RGBAColor {
        get { borderColorStore ?? .white }
        set { borderColorStore = newValue }
    }
}

/// Where the nameplate goes.
enum NameplateAnchor: String, Codable, CaseIterable, Identifiable {
    case aboveWebcam, belowWebcam, corner
    var id: String { rawValue }
    var label: String {
        switch self {
        case .aboveWebcam: return "Above Webcam"
        case .belowWebcam: return "Below Webcam"
        case .corner: return "Canvas Corner"
        }
    }
}

/// A "lower third" card: who is presenting.
struct NameplateSettings: Codable, Equatable {
    var enabled = false
    var name = "{fullname}"
    var title = ""
    var company = "{company}"
    var logoFile: String?
    /// Canvas corner used when the card isn't attached to the webcam.
    var corner = CanvasCorner.bottomLeft
    /// Optional so profiles saved before this existed still load; read `placement(with:)`.
    var anchor: NameplateAnchor?

    // Optionals below so profiles saved before they existed still load.
    private var borderStore: Bool?
    private var borderColorStore: RGBAColor?
    private var alignStore: HAlign?

    var border: Bool {
        get { borderStore ?? false }
        set { borderStore = newValue }
    }
    var borderColor: RGBAColor {
        get { borderColorStore ?? .white }
        set { borderColorStore = newValue }
    }
    /// How the card lines up with the webcam when it sits above or below it.
    var align: HAlign {
        get { alignStore ?? .center }
        set { alignStore = newValue }
    }

    /// Where the card actually goes: attached to the webcam only while the webcam is on.
    /// Unset, it sits under a side-by-side webcam and in its own corner otherwise.
    func placement(with cam: WebcamSettings) -> NameplateAnchor {
        guard cam.enabled else { return .corner }
        return anchor ?? (cam.layout == .side ? .belowWebcam : .corner)
    }
    var scale = 1.0
    var background = RGBAColor(0, 0, 0, 0.55)
    var textColor = RGBAColor.white
}

struct OverlayProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Untitled"
    var watermark = WatermarkSettings()
    var header = HeaderSettings()
    var footer = FooterSettings()
    var redactions: [Redaction] = []
    var statusBar = StatusBarSettings()
    var background = BackgroundSettings()
    // Added later: stored as optionals so profiles saved by older versions still load.
    private var webcamStore: WebcamSettings?
    private var nameplateStore: NameplateSettings?

    var webcam: WebcamSettings {
        get { webcamStore ?? WebcamSettings() }
        set { webcamStore = newValue }
    }
    var nameplate: NameplateSettings {
        get { nameplateStore ?? NameplateSettings() }
        set { nameplateStore = newValue }
    }

    static var defaults: [OverlayProfile] {
        var clean = OverlayProfile()
        clean.name = "Clean"

        var confidential = OverlayProfile()
        confidential.name = "Confidential"
        confidential.watermark.enabled = true
        confidential.footer.enabled = true

        var demo = OverlayProfile()
        demo.name = "Client Demo"
        demo.header.enabled = true
        demo.footer.enabled = true
        demo.footer.text = "Prepared for {company}. Confidential — not for redistribution."
        demo.statusBar.enabled = true

        return [clean, confidential, demo]
    }
}
