import SwiftUI

/// What the inspector is showing. Ordered the way a session is set up.
enum InspectorTab: String, CaseIterable, Identifiable {
    case canvas, device, camera, branding, presenter
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .canvas: return "photo.artframe"
        case .device: return "iphone"
        case .camera: return "person.crop.square"
        case .branding: return "seal"
        case .presenter: return "pencil.tip.crop.circle"
        }
    }
    var label: String {
        switch self {
        case .canvas: return "Canvas"
        case .device: return "Device"
        case .camera: return "Camera"
        case .branding: return "Branding"
        case .presenter: return "Presenter"
        }
    }
}

/// Settings panel: the profile on top, then one tab per job.
struct InspectorView: View {
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var presenter: PresenterModel
    @EnvironmentObject var model: AppModel

    @AppStorage("inspectorTab") private var tab = InspectorTab.canvas
    @State private var renaming = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let p = profiles.selectedBinding
        VStack(spacing: 0) {
            // 20pt matches the grouped form's own side inset, so everything lines up.
            profileBar(p)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            tabBar
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)

            Form {
                switch tab {
                case .canvas:
                    canvasSizeSection
                    backgroundSection(p.background)
                case .device:
                    frameSection
                    statusBarSection(p.statusBar)
                    redactionSection(p.redactions)
                case .camera:
                    // The webcam and nameplate are drawn on the canvas, so they only apply in
                    // Canvas mode. Frame Only shows the bare device.
                    if frameOnlyOutput {
                        Section {
                            Label("The webcam and nameplate appear on the canvas. The output window is in Frame Only mode, which shows just the device.",
                                  systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                            Button("Switch Output to Canvas") { settings.outputStyle = .canvas }
                        }
                    }
                    Group {
                        webcamSection(p.webcam)
                        nameplateSection(p.nameplate)
                    }
                    .disabled(frameOnlyOutput)
                case .branding:
                    watermarkSection(p.watermark)
                    headerSection(p.header)
                    footerSection(p.footer)
                    tokensSection
                    includeSection
                case .presenter:
                    presenterSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var frameOnlyOutput: Bool {
        model.outputDetached && settings.outputStyle == .frameOnly
    }

    // MARK: Tabs

    /// Equal-width icon-over-label tabs, like a Settings window's toolbar. A segmented
    /// control with four text labels is wider than the panel and spills past its padding.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { item in
                let selected = tab == item
                Button { tab = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16))
                            .frame(height: 20)
                        Text(item.label)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: Profile

    /// Everything on the Canvas, Device and Branding tabs is saved in the selected profile.
    private func profileBar(_ p: Binding<OverlayProfile>) -> some View {
        HStack(spacing: 8) {
            Text("Profile").foregroundStyle(.secondary)
            if renaming {
                TextField("Profile name", text: p.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { renaming = false }
                    .onChange(of: nameFocused) { _, focused in if !focused { renaming = false } }
                Button("Done") { renaming = false }
            } else {
                Picker("Profile", selection: $profiles.selectedID) {
                    ForEach(profiles.profiles) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .help("A profile saves the canvas, device and branding settings")
                Spacer(minLength: 0)
                Menu {
                    Button("Rename…") {
                        renaming = true
                        DispatchQueue.main.async { nameFocused = true }
                    }
                    Button("Duplicate") { profiles.duplicateSelected() }
                    Button("New Profile") { profiles.addProfile() }
                    Divider()
                    Button("Delete", role: .destructive) { profiles.deleteSelected() }
                        .disabled(profiles.profiles.count < 2)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Rename, duplicate or delete this profile")
            }
        }
    }

    private var canvasSizeSection: some View {
        Section {
            Picker("Size", selection: $settings.canvasPreset) {
                ForEach(CanvasPreset.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Canvas Size").font(.headline)
        } footer: {
            Text("Also the size of recordings and screenshots.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var frameSection: some View {
        Section {
            Picker("Frame color", selection: $settings.frameColor) {
                ForEach(FrameColor.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Frame").font(.headline)
        } footer: {
            Text("Pick the device model from the frame menu in the toolbar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tokensSection: some View {
        Section {
            TextField("Company", text: $settings.companyName)
            Text(verbatim: "Use in any text: \(Tokens.help)")
                .font(.caption2).foregroundStyle(.secondary)
                .textSelection(.enabled)
        } header: {
            Text("Text Tokens").font(.headline)
        }
    }

    private var includeSection: some View {
        Section {
            Toggle("Recordings", isOn: $settings.overlaysInRecordings)
            Toggle("Screenshots", isOn: $settings.overlaysInScreenshots)
            Toggle("Virtual camera", isOn: $settings.overlaysInVirtualCamera)
        } header: {
            Text("Show Branding In").font(.headline)
        } footer: {
            Text("Redactions and drawings are always included.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Camera

    @State private var webcams: [(id: String, name: String)] = []

    private func webcamSection(_ cam: Binding<WebcamSettings>) -> some View {
        Section {
            if cam.wrappedValue.enabled {
                Picker("Camera", selection: $settings.webcamID) {
                    Text("System default").tag("")
                    ForEach(webcams, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Layout", selection: cam.layout) {
                    ForEach(WebcamLayout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if cam.wrappedValue.layout == .corner {
                    LabeledContent("Position") { CornerPicker(selection: cam.corner) }
                } else {
                    Picker("Webcam side", selection: cam.side) {
                        ForEach(CanvasSide.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                slider("Size", cam.size, cam.wrappedValue.layout == .corner ? 0.08...0.4 : 0.15...0.45)
                Picker("Shape", selection: cam.shape) {
                    ForEach(WebcamShape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Mirror", isOn: cam.mirrored)
                BorderRow(isOn: cam.border, color: cam.borderColor)
            }
        } header: {
            Toggle("Webcam", isOn: cam.enabled).toggleStyle(.switch).font(.headline)
        } footer: {
            if cam.wrappedValue.enabled, cam.wrappedValue.layout == .side {
                Text("The device moves to the \(cam.wrappedValue.side == .left ? "right" : "left") to make room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            webcams = ScreenCaptureDevices.webcams().map { ($0.uniqueID, $0.localizedName) }
        }
    }

    private func nameplateSection(_ plate: Binding<NameplateSettings>) -> some View {
        Section {
            if plate.wrappedValue.enabled {
                TextField("Name", text: plate.name)
                TextField("Title", text: plate.title, prompt: Text("Optional"))
                TextField("Company", text: plate.company, prompt: Text("Optional"))
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
                slider("Size", plate.scale, 0.5...2.5)
                BorderRow(isOn: plate.border, color: plate.borderColor)
                ColorPicker("Card color", selection: plate.background.swiftUIColor)
                ColorPicker("Text color", selection: plate.textColor.swiftUIColor, supportsOpacity: false)
            }
        } header: {
            Toggle("Nameplate", isOn: plate.enabled).toggleStyle(.switch).font(.headline)
        } footer: {
            if plate.wrappedValue.enabled {
                Text("Text tokens such as {fullname} and {company} work here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Sections

    private func watermarkSection(_ wm: Binding<WatermarkSettings>) -> some View {
        Section {
            if wm.wrappedValue.enabled {
                Picker("Type", selection: wm.useImage) {
                    Text("Text").tag(false)
                    Text("Image").tag(true)
                }
                .pickerStyle(.segmented)
                if wm.wrappedValue.useImage {
                    HStack {
                        AssetThumbnail(fileName: wm.wrappedValue.imageFile)
                        Button("Choose Image…") {
                            if let f = Panels.importAsset(title: "Watermark image") { wm.wrappedValue.imageFile = f }
                        }
                    }
                    slider("Size", wm.imageWidth, 0.05...0.6)
                } else {
                    TextField("Text", text: wm.text, axis: .vertical)
                    slider("Font size", wm.fontSize, 10...120, format: "%.0f")
                    ColorPicker("Color", selection: wm.color.swiftUIColor, supportsOpacity: false)
                }
                Toggle("Tile across area", isOn: wm.tiled)
                if wm.wrappedValue.tiled { slider("Spacing", wm.spacing, 0.4...3) }
                slider("Opacity", wm.opacity, 0.02...1)
                slider("Angle", wm.angle, -90...90, format: "%.0f°")
                Picker("Cover", selection: wm.scope) {
                    ForEach(WatermarkScope.allCases) { Text($0.label).tag($0) }
                }
            }
        } header: {
            Toggle("Watermark", isOn: wm.enabled).toggleStyle(.switch).font(.headline)
        }
    }

    private func headerSection(_ h: Binding<HeaderSettings>) -> some View {
        Section {
            if h.wrappedValue.enabled {
                HStack {
                    AssetThumbnail(fileName: h.wrappedValue.logoFile)
                    Button("Choose Logo…") {
                        if let f = Panels.importAsset(title: "Header logo") { h.wrappedValue.logoFile = f }
                    }
                    if h.wrappedValue.logoFile != nil {
                        Button("Remove") { h.wrappedValue.logoFile = nil }
                    }
                }
                TextField("Title", text: h.title)
                TextField("Right side text", text: h.rightText)
                Picker("Align", selection: h.alignment) {
                    ForEach(HAlign.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Height", h.height, 0.03...0.2)
                ColorPicker("Text color", selection: h.textColor.swiftUIColor)
                Toggle("Divider line", isOn: h.showDivider)
            }
        } header: {
            Toggle("Header & Logo", isOn: h.enabled).toggleStyle(.switch).font(.headline)
        }
    }

    private func footerSection(_ f: Binding<FooterSettings>) -> some View {
        Section {
            if f.wrappedValue.enabled {
                HStack {
                    TextField("Badge", text: f.badge)
                    ColorPicker("", selection: f.badgeColor.swiftUIColor, supportsOpacity: false).labelsHidden()
                }
                TextField("Footnote", text: f.text, axis: .vertical)
                Picker("Align", selection: f.alignment) {
                    ForEach(HAlign.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Height", f.height, 0.025...0.12)
                ColorPicker("Text color", selection: f.textColor.swiftUIColor)
                Toggle("Divider line", isOn: f.showDivider)
            }
        } header: {
            Toggle("Confidentiality Footer", isOn: f.enabled).toggleStyle(.switch).font(.headline)
        }
    }

    private func redactionSection(_ list: Binding<[Redaction]>) -> some View {
        Section {
            Button {
                presenter.tool = .redact
            } label: {
                Label(presenter.tool == .redact ? "Drag on the device to add…" : "Add Redaction (Redact tool)",
                      systemImage: "rectangle.dashed")
            }
            ForEach(list) { $r in
                HStack {
                    Picker("Style", selection: $r.style) {
                        ForEach(RedactionStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    if r.style == .solid {
                        ColorPicker("", selection: $r.color.swiftUIColor, supportsOpacity: false).labelsHidden()
                    }
                    Spacer()
                    Text(verbatim: "\(Int(r.rect.width * 100))×\(Int(r.rect.height * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        let id = r.id
                        list.wrappedValue.removeAll { $0.id == id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
            }
            if !list.wrappedValue.isEmpty {
                Button("Remove All", role: .destructive) { list.wrappedValue.removeAll() }
            }
        } header: {
            Text("Redactions").font(.headline)
        } footer: {
            Text("Boxes stick to the device screen and apply to the preview and every output.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statusBarSection(_ sb: Binding<StatusBarSettings>) -> some View {
        Section {
            if sb.wrappedValue.enabled {
                TextField("Time", text: sb.time)
                TextField("iPad date", text: sb.iPadDate)
                Toggle("Cellular bars (iPhone)", isOn: sb.showCellular)
                Toggle("Match app color automatically", isOn: sb.autoColor)
                if !sb.wrappedValue.autoColor {
                    ColorPicker("Background", selection: sb.background.swiftUIColor, supportsOpacity: false)
                    ColorPicker("Text & icons", selection: sb.foreground.swiftUIColor, supportsOpacity: false)
                }
            }
        } header: {
            Toggle("Clean Status Bar", isOn: sb.enabled).toggleStyle(.switch).font(.headline)
        }
    }

    private func backgroundSection(_ bg: Binding<BackgroundSettings>) -> some View {
        Section {
            Picker("Style", selection: bg.style) {
                ForEach(BackgroundStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            ColorPicker(bg.wrappedValue.style == .gradient ? "From" : "Color", selection: bg.color1.swiftUIColor, supportsOpacity: false)
            if bg.wrappedValue.style == .gradient {
                ColorPicker("To", selection: bg.color2.swiftUIColor, supportsOpacity: false)
            }
            if bg.wrappedValue.style == .image {
                HStack {
                    AssetThumbnail(fileName: bg.wrappedValue.imageFile)
                    Button("Choose Image…") {
                        if let f = Panels.importAsset(title: "Background image") { bg.wrappedValue.imageFile = f }
                    }
                }
            }
            slider("Padding", bg.padding, 0...0.2)
        } header: {
            Text("Background").font(.headline)
        }
    }

    private var presenterSection: some View {
        Section {
            Toggle("Highlight cursor & clicks", isOn: $presenter.highlightCursor)
            ColorPicker("Pen color", selection: $presenter.penColor.swiftUIColor, supportsOpacity: false)
            slider("Pen width", $presenter.penWidth, 0.002...0.02, format: "%.3f")
            Picker("Fade drawings", selection: $settings.annotationFadeSeconds) {
                Text("Never").tag(0.0)
                Text("After 2 s").tag(2.0)
                Text("After 4 s").tag(4.0)
                Text("After 8 s").tag(8.0)
            }
        } header: {
            Text("Presenter").font(.headline)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String = "%.2f") -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
