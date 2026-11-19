import SwiftUI
import AppKit

/// "Support Us": opens the DevScape.io tip page in the default browser.
///
/// The app only ever knows the tip.devscape.io address; prices, payment links and page
/// wording live on the site. Nothing unlocks, and the app never learns whether anyone tipped.
enum SupportUs {
    /// Identifies this app on the tip page (drives its greeting and tags the payment).
    static let appID = "framecast"
    static let menuTitle = "Support Us ♥"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    static func open() {
        var url = URLComponents(string: "https://tip.devscape.io/")!
        url.queryItems = [.init(name: "app", value: appID), .init(name: "v", value: version)]
        if let link = url.url { NSWorkspace.shared.open(link) }
    }

    // MARK: Nudge

    private static let defaults = UserDefaults.standard
    private static let launchesKey = "supportNudge.launches"
    private static let sinceKey = "supportNudge.since"
    private static let doneKey = "supportNudge.done"

    /// Counts a launch and says whether the one small prompt is due: after the tenth launch
    /// or a week of use, and never again once it has been answered.
    static func registerLaunchAndCheck() -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return false }
        let launches = defaults.integer(forKey: launchesKey) + 1
        defaults.set(launches, forKey: launchesKey)
        let now = Date().timeIntervalSince1970
        var since = defaults.double(forKey: sinceKey)
        if since == 0 {
            since = now
            defaults.set(since, forKey: sinceKey)
        }
        return launches >= 10 || now - since >= 7 * 24 * 3600
    }

    /// "Not now": start the count again rather than asking at every launch.
    static func postponeNudge() {
        defaults.set(0, forKey: launchesKey)
        defaults.set(Date().timeIntervalSince1970, forKey: sinceKey)
    }

    /// "Don't show again", or they opened the page: never prompt again.
    static func finishNudge() {
        defaults.set(true, forKey: doneKey)
    }
}

/// The About window.
struct AboutView: View {
    static let windowID = "about"

    @State private var showLicense = false

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("FrameCast").font(.title.weight(.semibold))
                Text("Version \(SupportUs.version) (\(build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Mirror an iPhone or iPad in a device frame, then record it, capture it, or present it on a call.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                Text("FrameCast is free to use.")
                    .font(.callout.weight(.medium))
                Text("It may not be resold, in whole or in part, in any form or fashion.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("Apache License 2.0 with Commons Clause")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("View License") { showLicense = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(spacing: 8) {
                Button(SupportUs.menuTitle) { SupportUs.open() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                Text("FrameCast is made by DevScape.io. A tip helps cover hosting, code signing and development time. It’s entirely optional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(spacing: 2) {
                Text("Copyright © 2026 DevScape.io LLC")
                Link("devscape.io", destination: URL(string: "https://devscape.io")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .frame(width: 380)
        .translucentWindow()
        .sheet(isPresented: $showLicense) { LicenseView() }
    }
}

/// The full license text, read from the LICENSE file bundled with the app.
struct LicenseView: View {
    @Environment(\.dismiss) private var dismiss

    private static let text: String = {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "FrameCast is licensed under the Apache License, Version 2.0, with the Commons Clause License Condition v1.0.\n\nThe license file is missing from this build. See https://www.apache.org/licenses/LICENSE-2.0 and https://commonsclause.com."
        }
        return text
    }()

    var body: some View {
        VStack(spacing: 0) {
            Text("License").font(.headline).padding(.vertical, 12)
            Divider()
            ScrollView {
                Text(Self.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 520)
    }
}

/// The one small, dismissible prompt. Sits in a corner of the main window; never blocks the app.
struct SupportNudge: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Enjoying FrameCast?").font(.headline)
                Spacer()
                Button { close(.later) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Not now")
            }
            Text("FrameCast is made by DevScape.io. If it’s been useful, a tip helps cover hosting, code signing and development time. It’s entirely optional.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Support Us") {
                    SupportUs.open()
                    close(.never)
                }
                .buttonStyle(.borderedProminent)
                Button("Not now") { close(.later) }
                Spacer()
                Button("Don’t show again") { close(.never) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
        .glassPanel(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private enum Answer { case later, never }

    private func close(_ answer: Answer) {
        if answer == .never { SupportUs.finishNudge() } else { SupportUs.postponeNudge() }
        withAnimation { model.showSupportNudge = false }
    }
}
