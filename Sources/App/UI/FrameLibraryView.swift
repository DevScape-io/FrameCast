import SwiftUI

/// Settings tab: imported bezel images. Pick one on the left to edit it on the right.
/// (Default frame, frame color and USB model detection are on the Devices tab.)
struct FrameLibraryView: View {
    @EnvironmentObject var frames: FrameLibrary
    @State private var selection: UUID?
    @State private var importMessage: String?
    @State private var importing = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    // Ungrouped frames first, then one section per imported subfolder.
                    ForEach(frames.frames.filter { $0.group == nil }) { row($0) }
                    ForEach(frames.groups, id: \.self) { group in
                        Section {
                            ForEach(frames.frames.filter { $0.group == group }) { row($0) }
                        } header: {
                            Text(group)
                                .contextMenu {
                                    Button("Remove Group", role: .destructive) {
                                        if frames.frames.contains(where: { $0.id == selection && $0.group == group }) { selection = nil }
                                        frames.removeGroup(group)
                                    }
                                }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .overlay {
                    if frames.frames.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down").font(.title2)
                            Text("Drop frame images or folders here")
                                .font(.callout)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .padding()
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    Button(action: importFromPanel) { Image(systemName: "plus") }
                        .help("Add images, or a folder of images")
                    Button {
                        if let id = selection, let f = frames.frame(id: id) { frames.remove(f); selection = nil }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Remove the selected frame")
                    Spacer()
                    if importing { ProgressView().controlSize(.small) }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(width: 220)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                importURLs(urls)
                return true
            } isTargeted: { dropTargeted = $0 }

            Divider()

            Form {
                if let id = selection, let index = frames.frames.firstIndex(where: { $0.id == id }) {
                    FrameEditor(frame: $frames.frames[index])
                } else {
                    Section {
                        Text("FrameCast draws a built-in frame for every supported iPhone and iPad. For pixel-perfect frames, download Apple’s official product bezels and import the PNGs here: use the + button, or drag images or a whole folder into the list. Images in subfolders are grouped by folder. The transparent screen area is found automatically and each frame is linked to its model.")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Import Frames…", action: importFromPanel)
                            Link("Apple Design Resources", destination: URL(string: "https://developer.apple.com/design/resources/#product-bezels")!)
                        }
                    } header: {
                        Text("Imported Frames")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK") { importMessage = nil }
        } message: { Text(importMessage ?? "") }
    }

    private func row(_ f: ImportedFrame) -> some View {
        HStack {
            if let img = frames.image(for: f) {
                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
            }
            VStack(alignment: .leading) {
                Text(f.name).lineLimit(1)
                Text(f.linkedSpecID.flatMap { DeviceCatalog.spec(id: $0)?.name } ?? "Not linked")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .tag(f.id)
        .contextMenu {
            Button("Remove", role: .destructive) {
                if selection == f.id { selection = nil }
                frames.remove(f)
            }
        }
    }

    private func importFromPanel() {
        importURLs(Panels.chooseImagesOrFolders(title: "Import device frames"))
    }

    /// Files and folders from the + button or a drop.
    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let items = FrameLibrary.importItems(from: urls)
        guard !items.isEmpty else {
            importMessage = "No images were found."
            return
        }
        importing = true
        frames.importFrames(items) { added, failed in
            importing = false
            if let first = added.first { selection = first.id }
            if failed > 0 {
                importMessage = "\(failed) file\(failed == 1 ? "" : "s") couldn’t be read as an image."
            }
        }
    }
}

private struct FrameEditor: View {
    @Binding var frame: ImportedFrame
    @EnvironmentObject var frames: FrameLibrary

    var body: some View {
        Section("Frame") {
            TextField("Name", text: $frame.name)
            TextField("Group", text: Binding(get: { frame.group ?? "" },
                                             set: { frame.group = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }),
                      prompt: Text("None"))
            Picker("Device model", selection: $frame.linkedSpecID) {
                Text("Not linked").tag(String?.none)
                ForEach(DeviceCatalog.all) { Text($0.name).tag(String?.some($0.id)) }
            }
            Picker("Orientation", selection: $frame.isLandscape) {
                Text("Portrait").tag(false)
                Text("Landscape").tag(true)
            }
            .pickerStyle(.segmented)
        }
        Section("Screen area") {
            if let img = frames.image(for: frame) {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        GeometryReader { geo in
                            let r = frame.screenRect
                            Rectangle()
                                .stroke(Color.pink, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                .frame(width: r.width * geo.size.width, height: r.height * geo.size.height)
                                .offset(x: r.minX * geo.size.width, y: r.minY * geo.size.height)
                        }
                    }
                    .frame(maxHeight: 220)
            }
            HStack {
                coordinate("X", $frame.screenRect.origin.x)
                coordinate("Y", $frame.screenRect.origin.y)
                coordinate("W", $frame.screenRect.size.width)
                coordinate("H", $frame.screenRect.size.height)
            }
            Button("Detect Automatically") { frames.redetect(frame) }
        }
    }

    private func coordinate(_ label: String, _ value: Binding<CGFloat>) -> some View {
        TextField(label, value: value.double, format: .number.precision(.fractionLength(3)))
            .frame(width: 70)
    }
}
