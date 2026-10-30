import AppKit
import Carbon

final class Hotkeys {
    var handler: ((UInt32) -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    var unavailable: [UInt32] = []
    func register() {
        refs.values.forEach { UnregisterEventHotKey($0) }; refs = [:]; unavailable = []
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
            if status == noErr, let ref { refs[shortcut.id] = ref } else { unavailable.append(shortcut.id) }
        }
    }
    /// Lets these keys through as ordinary key presses until the next `register()`.
    func suspend(_ ids: Set<UInt32>) { for id in ids { if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) } } }
    deinit { refs.values.forEach { UnregisterEventHotKey($0) }; if let eventHandler { RemoveEventHandler(eventHandler) } }
}
