import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Gives SwiftUI access to the hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onWindow(w) } }
    }
}

enum Panels {
    static func chooseImage(title: String = "Choose an image") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .pdf, .svg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseImages(title: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.png, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Image files and/or folders of images.
    static func chooseImagesOrFolders(title: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "Choose images, or a folder to add every image inside it."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.image, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseFolder(current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Imports an image into the asset store and returns its file name.
    static func importAsset(title: String) -> String? {
        guard let url = chooseImage(title: title) else { return nil }
        return try? AssetStore.shared.importImage(from: url)
    }
}

extension Binding where Value == CGFloat {
    var double: Binding<Double> {
        Binding<Double>(get: { Double(self.wrappedValue) }, set: { self.wrappedValue = CGFloat($0) })
    }
}

/// A small image thumbnail for an asset file name.
struct AssetThumbnail: View {
    let fileName: String?
    var body: some View {
        Group {
            if let img = AssetStore.shared.asset(fileName) {
                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 28)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
