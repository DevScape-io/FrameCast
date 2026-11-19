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

struct OverlayProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Untitled"
    var watermark = WatermarkSettings()
    var header = HeaderSettings()
    var footer = FooterSettings()
    var redactions: [Redaction] = []
    var statusBar = StatusBarSettings()
    var background = BackgroundSettings()

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
