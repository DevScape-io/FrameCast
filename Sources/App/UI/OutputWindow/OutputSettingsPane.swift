import SwiftUI

/// Everything that used to need the main window, shown when the output's strip is expanded:
/// the source, the output style, then the same settings panel (profile and tabs) the main
/// window uses. One set of controls, so there is nothing to keep in sync.
struct OutputSettingsPane: View {
    @ObservedObject var chrome: OutputChrome
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    DevicePicker().labelsHidden()
                    FrameMenu()
                }
                Picker("Output", selection: $settings.outputStyle) {
                    ForEach(OutputStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if settings.outputStyle == .frameOnly {
                    HStack {
                        Text("Size")
                        Slider(value: Binding(get: { chrome.frameHeight }, set: { chrome.setFrameHeight($0) }),
                               in: chrome.frameHeightRange)
                    }
                    .help("Size of the floating device. You can also pinch on it.")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            Divider().padding(.top, 8)

            InspectorView()
        }
    }
}
