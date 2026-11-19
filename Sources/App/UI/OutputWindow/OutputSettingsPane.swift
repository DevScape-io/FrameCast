import SwiftUI

/// Output settings shown when the strip is expanded: what the output is, then each thing
/// on the canvas in the order it's layered (background → device → webcam → nameplate).
struct OutputCustomizeView: View {
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
