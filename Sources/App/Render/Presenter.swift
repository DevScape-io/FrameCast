import Foundation
import CoreGraphics
import QuartzCore

enum PresenterTool: String, CaseIterable, Identifiable {
    case pointer, pen, highlighter, spotlight, zoom, redact
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pointer: return "Pointer"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .spotlight: return "Spotlight"
        case .zoom: return "Zoom Lens"
        case .redact: return "Redact"
        }
    }
    var symbol: String {
        switch self {
        case .pointer: return "cursorarrow.rays"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .spotlight: return "flashlight.on.fill"
        case .zoom: return "plus.magnifyingglass"
        case .redact: return "eye.slash"
        }
    }
    var hint: String {
        switch self {
        case .pointer: return "Highlights the cursor and shows click ripples"
        case .pen: return "Draw on the capture"
        case .highlighter: return "Translucent marker"
        case .spotlight: return "Dims everything except around the cursor (scroll to resize)"
        case .zoom: return "Magnifies around the cursor (scroll to change zoom)"
        case .redact: return "Drag over the device to blur an area; right-click a box to remove it"
        }
    }
}

struct Stroke {
    var points: [CGPoint]      // normalized canvas coordinates, top-left origin
    var color: RGBAColor
    var width: CGFloat         // fraction of canvas height
    var highlighter: Bool
    var endedAt: CFTimeInterval?
}

struct ClickRipple {
    var point: CGPoint
    var time: CFTimeInterval
}

/// Everything the renderer needs to draw presenter tools. Owned by RenderLoop behind a lock.
struct PresenterSnapshot {
    var tool: PresenterTool = .pointer
    var cursor: CGPoint?
    var strokes: [Stroke] = []
    var clicks: [ClickRipple] = []
    var highlightCursor = true
    var spotlightRadius: CGFloat = 0.12
    var zoomFactor: CGFloat = 2
    var lensRadius: CGFloat = 0.15
    var pendingRedaction: CGRect?
    var countdown: Int?
}

/// UI-facing presenter options.
final class PresenterModel: ObservableObject {
    @Published var tool: PresenterTool = .pointer
    @Published var penColor = RGBAColor(1, 0.23, 0.19)
    @Published var penWidth: Double = 0.006
    @Published var highlightCursor = true
}

extension PresenterSnapshot {
    /// The preview-only state (pending redaction box) re-expressed in a crop of the canvas.
    func cropped(to crop: CGRect, canvas: CGSize) -> PresenterSnapshot {
        var p = self
        if let r = pendingRedaction, crop.width > 0, crop.height > 0 {
            p.pendingRedaction = CGRect(x: (r.minX * canvas.width - crop.minX) / crop.width,
                                        y: (r.minY * canvas.height - crop.minY) / crop.height,
                                        width: r.width * canvas.width / crop.width,
                                        height: r.height * canvas.height / crop.height)
        }
        return p
    }
}
