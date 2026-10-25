import AppKit
import Carbon

final class Hotkeys {
    var handler: ((UInt32) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    var unavailable: [UInt32] = []
    func register() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []; unavailable = []
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return noErr }
            var hotkey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
            Unmanaged<Hotkeys>.fromOpaque(data).takeUnretainedValue().handler?(hotkey.id)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        // ⇧⌘4 only reaches Still once the matching macOS screenshot shortcut is turned off.
        for shortcut in Shortcut.load() {
            guard let key = shortcut.keyCode else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key, shortcut.modifiers, EventHotKeyID(signature: 0x5354494C, id: shortcut.id), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { unavailable.append(shortcut.id) }
        }
    }
    deinit { refs.forEach { UnregisterEventHotKey($0) }; if let eventHandler { RemoveEventHandler(eventHandler) } }
}
