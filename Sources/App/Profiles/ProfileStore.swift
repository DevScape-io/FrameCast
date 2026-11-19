import Foundation
import SwiftUI

/// Overlay presets ("profiles"): watermark + header + footer + redactions + status bar + background.
final class ProfileStore: ObservableObject {
    @Published var profiles: [OverlayProfile] { didSet { scheduleSave() } }
    @Published var selectedID: UUID {
        didSet { UserDefaults.standard.set(selectedID.uuidString, forKey: "selectedProfileID") }
    }

    private var saveWork: DispatchWorkItem?

    init() {
        var loaded: [OverlayProfile] = []
        if let data = try? Data(contentsOf: AppPaths.profilesFile),
           let list = try? JSONDecoder().decode([OverlayProfile].self, from: data) {
            loaded = list
        }
        if loaded.isEmpty { loaded = OverlayProfile.defaults }
        let savedID = UserDefaults.standard.string(forKey: "selectedProfileID").flatMap(UUID.init(uuidString:))
        profiles = loaded
        selectedID = loaded.first(where: { $0.id == savedID })?.id ?? loaded[0].id
    }

    var selected: OverlayProfile {
        get { profiles.first { $0.id == selectedID } ?? profiles[0] }
        set {
            if let i = profiles.firstIndex(where: { $0.id == newValue.id }) { profiles[i] = newValue }
        }
    }

    var selectedBinding: Binding<OverlayProfile> {
        Binding(get: { self.selected }, set: { self.selected = $0 })
    }

    func addProfile() {
        var p = OverlayProfile()
        p.name = "New Profile"
        profiles.append(p)
        selectedID = p.id
    }

    func duplicateSelected() {
        var p = selected
        p.id = UUID()
        p.name += " Copy"
        profiles.append(p)
        selectedID = p.id
    }

    func deleteSelected() {
        guard profiles.count > 1 else { return }
        let id = selectedID
        profiles.removeAll { $0.id == id }
        selectedID = profiles[0].id
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = profiles
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: AppPaths.profilesFile, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
