import SwiftUI

/// Which connected iPhone or iPad to show.
struct DevicePicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Device", selection: $model.selectedDeviceID) {
            Text("No Device").tag(String?.none)
            ForEach(model.devices) { d in
                Text(d.name).tag(String?.some(d.id))
            }
        }
        .help("Connected iPhone or iPad")
    }
}

/// Which frame to draw around the device.
struct FrameMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var frames: FrameLibrary

    var body: some View {
        Menu {
            frameButton("Auto (detect model)", id: "auto")
            frameButton("No Frame", id: "none")
            Divider()
            Menu("Built-in Frames") {
                ForEach(DeviceCatalog.all) { spec in
                    frameButton(spec.name, id: "builtin:\(spec.id)")
                }
            }
            Menu("Imported Frames") {
                if frames.frames.isEmpty {
                    Text("None yet")
                }
                ForEach(frames.frames) { f in
                    frameButton(f.name, id: "imported:\(f.id.uuidString)")
                }
            }
            Divider()
            Button("Import Frame Image…") {
                for url in Panels.chooseImages(title: "Import device frame (PNG with transparent screen)") {
                    if let f = try? frames.importFrame(from: url) {
                        model.frameSelection = "imported:\(f.id.uuidString)"
                    }
                }
            }
            Button("Read Model Over USB Again") { model.reidentify() }
            Picker("Frame Color", selection: $settings.frameColor) {
                ForEach(FrameColor.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Button("Use This Frame for New Devices") {
                settings.defaultFrameID = model.frameSelection
            }
        } label: {
            Label(model.frameMenuLabel, systemImage: model.resolvedSpec.family == .iPhone ? "iphone" : "ipad")
                .labelStyle(.titleAndIcon)
        }
        .help("Device frame")
    }

    @ViewBuilder
    private func frameButton(_ title: String, id: String) -> some View {
        Button {
            model.frameSelection = id
        } label: {
            if model.frameSelection == id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
