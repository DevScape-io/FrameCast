import AppKit
import SwiftUI

/// A Codable sRGB color used throughout profiles and settings.
struct RGBAColor: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? NSColor.black
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }

    var cgColor: CGColor { CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var contrasting: RGBAColor { luminance > 0.55 ? .black : .white }

    func withAlpha(_ alpha: Double) -> RGBAColor { RGBAColor(r, g, b, alpha) }

    static let white = RGBAColor(1, 1, 1)
    static let black = RGBAColor(0, 0, 0)
    static let red = RGBAColor(0.86, 0.15, 0.15)
    static let gray = RGBAColor(0.5, 0.5, 0.5)
    static let yellow = RGBAColor(1, 0.84, 0.1)
}

extension Binding where Value == RGBAColor {
    /// Bridges an RGBAColor binding to SwiftUI's ColorPicker.
    var swiftUIColor: Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: self.wrappedValue.nsColor) },
            set: { self.wrappedValue = RGBAColor(nsColor: NSColor($0)) }
        )
    }
}
