import SwiftUI

/// A 2×2 grid for choosing a corner of the canvas.
struct CornerPicker: View {
    @Binding var selection: CanvasCorner

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow { cell(.topLeft); cell(.topRight) }
            GridRow { cell(.bottomLeft); cell(.bottomRight) }
        }
        .padding(3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func cell(_ corner: CanvasCorner) -> some View {
        Button { selection = corner } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(selection == corner ? Color.accentColor : Color.secondary.opacity(0.25))
                .frame(width: 30, height: 20)
        }
        .buttonStyle(.plain)
        .help(corner.label)
        .accessibilityLabel(corner.label)
        .accessibilityAddTraits(selection == corner ? .isSelected : [])
    }
}

/// Nameplate placement: above or below the webcam (when it's on), or a canvas corner.
struct NameplatePlacementRows: View {
    @Binding var plate: NameplateSettings
    let webcam: WebcamSettings

    var body: some View {
        if webcam.enabled {
            Picker("Placement", selection: Binding(get: { plate.placement(with: webcam) }, set: { plate.anchor = $0 })) {
                ForEach(NameplateAnchor.allCases) { Text($0.label).tag($0) }
            }
        }
        if plate.placement(with: webcam) == .corner {
            LabeledContent("Position") { CornerPicker(selection: $plate.corner) }
        } else {
            Picker("Justify", selection: $plate.align) {
                Image(systemName: "align.horizontal.left").tag(HAlign.left).help("Left edge of the webcam")
                Image(systemName: "align.horizontal.center").tag(HAlign.center).help("Centered on the webcam")
                Image(systemName: "align.horizontal.right").tag(HAlign.right).help("Right edge of the webcam")
            }
            .pickerStyle(.segmented)
        }
    }
}

/// A border on/off switch with its color beside it.
struct BorderRow: View {
    @Binding var isOn: Bool
    @Binding var color: RGBAColor

    var body: some View {
        HStack {
            Toggle("Border", isOn: $isOn)
            if isOn {
                ColorPicker("Border color", selection: $color.swiftUIColor)
                    .labelsHidden()
            }
        }
    }
}
