import SwiftUI

/// Start/stop recording, showing the countdown and elapsed time.
struct RecordButton: View {
    @EnvironmentObject var model: AppModel
    /// Icon-only, for the output window's vertical strip.
    var compact = false

    var body: some View {
        Button { model.toggleRecording() } label: {
            if compact {
                compactLabel
            } else if model.isRecording, let start = model.recordingStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Label(Self.elapsed(from: start, to: context.date), systemImage: "stop.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.red)
                        .monospacedDigit()
                }
            } else if let c = model.countdown {
                Label("\(c)…", systemImage: "timer").labelStyle(.titleAndIcon)
            } else {
                Label("Record", systemImage: "record.circle").labelStyle(.titleAndIcon)
            }
        }
        .help("Start/stop recording (⇧⌘R, or ⌃⌥⌘R anywhere)")
    }

    @ViewBuilder
    private var compactLabel: some View {
        VStack(spacing: 1) {
            if model.isRecording, let start = model.recordingStartedAt {
                Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Self.elapsed(from: start, to: context.date))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.red)
                }
            } else if let c = model.countdown {
                Text("\(c)").font(.system(size: 15, weight: .bold).monospacedDigit())
            } else {
                Image(systemName: "record.circle").foregroundStyle(.red)
            }
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Microphone narration on/off.
struct MicToggle: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        Toggle(isOn: $settings.recordMicrophone) {
            Label("Microphone", systemImage: settings.recordMicrophone ? "mic.fill" : "mic.slash")
        }
        .help("Record microphone narration with the video")
    }
}

/// Virtual camera on/off.
struct VirtualCameraToggle: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Toggle(isOn: Binding(get: { model.virtualCameraOn }, set: { model.setVirtualCamera($0) })) {
            Label("Virtual Camera", systemImage: model.virtualCameraOn ? "video.fill" : "video")
        }
        .help("Virtual camera — show the framed device in Zoom, Teams, Meet")
    }
}
