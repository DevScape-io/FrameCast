import SwiftUI

@main
struct FrameCastApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("FrameCast", id: "main") {
            MainView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.profiles)
                .environmentObject(model.presenter)
                .environmentObject(model.frames)
                .onAppear { model.bootstrap() }
        }
        .defaultSize(width: 1280, height: 860)
        .commands { FrameCastCommands(model: model, presenter: model.presenter, settings: model.settings) }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.frames)
                .environmentObject(model.vcamInstaller)
                .scrollContentBackground(.hidden)
                .translucentWindow()
        }
    }
}

struct FrameCastCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var presenter: PresenterModel
    @ObservedObject var settings: AppSettings

    var body: some Commands {
        CommandMenu("Capture") {
            Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Take Screenshot") { model.takeScreenshot() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Toggle("Record Microphone", isOn: $settings.recordMicrophone)
            Toggle("Virtual Camera", isOn: Binding(get: { model.virtualCameraOn }, set: { model.setVirtualCamera($0) }))
            Divider()
            Button("Refresh Devices") { model.refreshDevices() }
            Button("Show Recordings Folder") { model.revealRecordings() }
        }
        // Window layout goes in the standard View menu.
        CommandGroup(before: .toolbar) {
            Toggle("Separate Output Window", isOn: $model.outputDetached)
                .keyboardShortcut("o", modifiers: [.command, .option])
            Picker("Output Style", selection: $settings.outputStyle) {
                ForEach(OutputStyle.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!model.outputDetached)
            Toggle("Float on Top", isOn: $model.alwaysOnTop)
            Toggle("Show Inspector", isOn: $model.showInspector)
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.outputDetached)
            Divider()
        }
        CommandMenu("Tools") {
            ForEach(Array(PresenterTool.allCases.enumerated()), id: \.element) { index, tool in
                Button(tool.label) { presenter.tool = tool }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button("Clear Drawings") { model.clearAnnotations() }
                .keyboardShortcut("k", modifiers: .command)
        }
    }
}
