import SwiftUI
import AppKit

/// Holds a weak reference to a hosting window so views can act on it later.
final class WindowBox {
    weak var window: NSWindow?
}

/// Behind-window blur for macOS 14, where SwiftUI can't set a material window background.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension View {
    /// Makes the whole window translucent so the desktop shows through, and lets the
    /// toolbar float as glass over the content instead of sitting on an opaque bar.
    @ViewBuilder
    func translucentWindow(_ material: Material = .ultraThinMaterial) -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(material, for: .window)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self.background(VisualEffectBackground().ignoresSafeArea())
        }
    }

    /// Liquid Glass on macOS 26 and later, falling back to a material on earlier systems.
    @ViewBuilder
    func glassPanel<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// A Liquid Glass button style on macOS 26 and later, borderless before that.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.borderless)
        }
    }
}
