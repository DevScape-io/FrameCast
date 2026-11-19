import Foundation
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon's RegisterEventHotKey (no Accessibility permission required).
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    private var refs: [EventHotKeyRef] = []
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4652_4D43), id: id) // 'FRMC'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hotKeyID)
            if err == noErr {
                let id = hotKeyID.id
                DispatchQueue.main.async { GlobalHotKeys.shared.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
