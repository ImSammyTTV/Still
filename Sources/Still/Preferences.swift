import SwiftUI
import ServiceManagement
import Carbon
import StillCore

@MainActor final class Preferences: ObservableObject {
    static let shared = Preferences()
    @AppStorage("recordingAutomation") var recordingAutomation = false
    @AppStorage("recordingStartShortcut") var recordingStartShortcut = ""
    @AppStorage("recordingEndShortcut") var recordingEndShortcut = ""
    @AppStorage("clickColor") var clickColor = "FF485E"
    @AppStorage("clickSize") var clickSize: Double = 1
    @AppStorage("clickStyle") var clickStyle = "outline"
    @AppStorage("clickAnimated") var clickAnimated = true
    @AppStorage("keysSize") var keysSize: Double = 1
    @AppStorage("keysStyle") var keysStyle = "dark"
    @AppStorage("keysPosition") var keysPosition = "bottomCenter"
    @AppStorage("cameraPosition") var cameraPosition = "bottomRight"
    @AppStorage("cameraFullscreen") var cameraFullscreen = false
    @AppStorage("cameraMirror") var cameraMirror = true
    var recordingPresentation: VideoSettings {
        var s = VideoSettings(); s.fps = recordingFPS; s.quality = recordingQuality
        s.cursorScale = recordingCursor ? 1 : 0; s.showClicks = recordingClicks; s.showKeystrokes = recordingKeys
        s.clickColor = clickColor; s.clickSize = clickSize; s.clickStyle = clickStyle; s.clickAnimated = clickAnimated
        s.keysSize = keysSize; s.keysStyle = keysStyle; let k = Self.position(keysPosition); s.keysX = k.x; s.keysY = k.y
        let c = Self.position(cameraPosition); s.cameraX = c.x; s.cameraY = c.y; s.cameraShape = recordingCameraShape; s.cameraFullscreen = cameraFullscreen; s.cameraMirror = cameraMirror
        return s
    }
    static func position(_ name: String) -> CGPoint { CGPoint(x: name.contains("Left") ? 0.03 : name.contains("Right") ? 0.97 : 0.5, y: name.contains("top") ? 0.03 : 0.97) }
    @AppStorage("recordingQuality") var recordingQuality = "high"
    @AppStorage("recordingCameraID") var recordingCameraID = ""
    @AppStorage("recordingMicrophoneID") var recordingMicrophoneID = ""
    @AppStorage("showMenuBar") var showMenuBar = true
    @AppStorage("hideDesktop") var hideDesktop = false
    @AppStorage("previewSwipeLeft") var previewSwipeLeft = "dismiss"
    @AppStorage("previewSwipeRight") var previewSwipeRight = "copy"
    @AppStorage("previewPosition") var previewPosition = "bottomLeft"
    @AppStorage("previewWidth") var previewWidth: Double = 280
    @AppStorage("previewTimeout") var previewTimeout: Double = 15
    @AppStorage("saveAfterCapture") var saveAfterCapture = false
    @AppStorage("annotateAfterCapture") var annotateAfterCapture = false
    @AppStorage("pinAfterCapture") var pinAfterCapture = false
    @AppStorage("recordingPreview") var recordingPreview = true
    @AppStorage("copyRecording") var copyRecording = false
    @AppStorage("openVideoEditor") var openVideoEditor = false
    @AppStorage("includeCursor") var includeCursor = false
    @AppStorage("windowShadow") var windowShadow = true
    /// Capture Still's own Settings, editor and History windows (its floating overlays stay out).
    @AppStorage("captureOwnWindows") var captureOwnWindows = true
    /// Let hold-Space window picking include menus, Spotlight, popovers and other pop-ups.
    @AppStorage("pickPopups") var pickPopups = true
    @AppStorage("windowBackground") var windowBackground = false
    @AppStorage("windowPadding") var windowPadding: Double = 40
    @AppStorage("freezeScreen") var freezeScreen = false
    @AppStorage("crosshair") var crosshair = "full"
    @AppStorage("magnifier") var magnifier = true
    @AppStorage("rememberSelection") var rememberSelection = true
    @AppStorage("exportFormat") var exportFormat = "png"
    @AppStorage("filenamePattern") var filenamePattern = "Screenshot {date} at {time}"
    @AppStorage("retentionDays") var retentionDays = 0
    @AppStorage("ocrLanguage") var ocrLanguage = "auto"
    @AppStorage("ocrLineBreaks") var ocrLineBreaks = true
    @AppStorage("pinRounded") var pinRounded = true
    @AppStorage("pinShadow") var pinShadow = true
    @AppStorage("pinBorder") var pinBorder = false
    @AppStorage("allowURLScheme") var allowURLScheme = true
    @AppStorage("recordingFPS") var recordingFPS = 30
    @AppStorage("recordingFormat") var recordingFormat = "mp4"
    @AppStorage("recordingResolution") var recordingResolution = 3840
    @AppStorage("recordingCursor") var recordingCursor = true
    @AppStorage("recordingClicks") var recordingClicks = false
    @AppStorage("recordingKeys") var recordingKeys = false
    @AppStorage("recordingCommandKeysOnly") var recordingCommandKeysOnly = true
    @AppStorage("recordingCamera") var recordingCamera = false
    @AppStorage("recordingCameraSize") var recordingCameraSize: Double = 180
    @AppStorage("recordingCameraShape") var recordingCameraShape = "circle"
    @AppStorage("gifFPS") var gifFPS = 12
    @AppStorage("gifWidth") var gifWidth = 800
    @AppStorage("wallpaperMode") var wallpaperMode = "desktop"
    @AppStorage("wallpaperImage") var wallpaperImage = ""
    @AppStorage("wallpaperColor") var wallpaperColor = "263547"
    @AppStorage("annotateDefaultTool") var annotateDefaultTool = "arrow"
    @AppStorage("annotateDefaultColor") var annotateDefaultColor = "FF414E"
    @AppStorage("annotateDefaultWidth") var annotateDefaultWidth: Double = 5
    @AppStorage("cloudEndpoint") var cloudEndpoint = ""
    @AppStorage("cloudExpiry") var cloudExpiry = 7
    /// Where Upload sends files: "still" (a Still Cloud server) or "drive" (Google Drive).
    @AppStorage("cloudProvider") var cloudProvider = "still"
    @AppStorage("driveAccess") var driveAccess = "link"
    @AppStorage("driveEmail") var driveEmail = ""
    @AppStorage("driveFolder") var driveFolder = ""
    @AppStorage("askUploadOptions") var askUploadOptions = false
    @AppStorage("autoUploadImages") var autoUploadImages = false
    @AppStorage("autoUploadVideos") var autoUploadVideos = false
    @AppStorage("appearance") var appearance = "system"
    private var defaultsObserver: NSObjectProtocol?
    init() { defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } } }
    func setLaunchAtLogin(_ value: Bool) throws {
        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        objectWillChange.send()
    }
    deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }
}

struct Shortcut: Codable, Identifiable, Equatable {
    var id: UInt32
    var title: String
    var keyCode: UInt32?
    var modifiers: UInt32
    var label: String
    static let defaults: [Shortcut] = [
        .init(id: 5, title: "Capture Bar", keyCode: 0x01, modifiers: UInt32(cmdKey|shiftKey|controlKey), label: "⌃⇧⌘S"),
        .init(id: 1, title: "Capture Area", keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey|shiftKey), label: "⇧⌘4"),
        .init(id: 2, title: "Capture Window", keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey|shiftKey|controlKey), label: "⌃⇧⌘4"),
        .init(id: 3, title: "Capture Fullscreen", keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey|shiftKey|controlKey), label: "⌃⇧⌘5"),
        .init(id: 4, title: "Start / Stop Recording", keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(cmdKey|shiftKey|controlKey), label: "⌃⇧⌘6"),
        .init(id: 6, title: "Capture Previous Area", modifiers: 0, label: ""),
        .init(id: 7, title: "Scrolling Capture", modifiers: 0, label: ""),
        .init(id: 8, title: "Capture Text (OCR)", modifiers: 0, label: ""),
        .init(id: 9, title: "Open Capture History", modifiers: 0, label: ""),
        .init(id: 10, title: "Restore Last Capture", modifiers: 0, label: ""),
        .init(id: 11, title: "Toggle Desktop Icons", modifiers: 0, label: ""),
        .init(id: 12, title: "Hide / Show Overlays", modifiers: 0, label: ""),
        .init(id: 13, title: "Clipboard History", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey|shiftKey), label: "⇧⌘V")
    ]
    static func load() -> [Shortcut] {
        guard let data = UserDefaults.standard.data(forKey: "shortcuts"), var saved = try? JSONDecoder().decode([Shortcut].self, from: data) else { return defaults }
        // Area capture moved from ⌃⇧⌘3 to ⇧⌘4; upgrade saved lists that still hold the old default.
        if UserDefaults.standard.integer(forKey: "shortcutsVersion") < 2 {
            if let index = saved.firstIndex(where: { $0.id == 1 && $0.keyCode == UInt32(kVK_ANSI_3) && $0.modifiers == UInt32(cmdKey|shiftKey|controlKey) }) { saved[index] = defaults[1] }
            UserDefaults.standard.set(2, forKey: "shortcutsVersion")
            if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: "shortcuts") }
        }
        // Older builds stored shifted characters in labels (⇧⌘$ instead of ⇧⌘4); rebuild them from the key code.
        if UserDefaults.standard.integer(forKey: "shortcutsVersion") < 3 {
            for index in saved.indices { if let code = saved[index].keyCode { saved[index].label = label(code: code, modifiers: saved[index].modifiers) ?? saved[index].label } }
            UserDefaults.standard.set(3, forKey: "shortcutsVersion")
            if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: "shortcuts") }
        }
        return defaults.map { base in saved.first(where: { $0.id == base.id }) ?? base }
    }
    static func label(code: UInt32, modifiers: UInt32) -> String? {
        guard let key = keyCharacters[code] else { return nil }
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key.uppercased()
    }
    static let keyCharacters: [UInt32: String] = {
        var map: [UInt32: String] = [:]
        let digits: [Int] = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (n, code) in digits.enumerated() { map[UInt32(code)] = String(n) }
        let letters: [(Int, String)] = [(kVK_ANSI_A, "a"), (kVK_ANSI_S, "s"), (kVK_ANSI_D, "d"), (kVK_ANSI_F, "f"), (kVK_ANSI_H, "h"), (kVK_ANSI_G, "g"), (kVK_ANSI_Z, "z"), (kVK_ANSI_X, "x"), (kVK_ANSI_C, "c"), (kVK_ANSI_V, "v"), (kVK_ANSI_B, "b"), (kVK_ANSI_Q, "q"), (kVK_ANSI_W, "w"), (kVK_ANSI_E, "e"), (kVK_ANSI_R, "r"), (kVK_ANSI_Y, "y"), (kVK_ANSI_T, "t"), (kVK_ANSI_O, "o"), (kVK_ANSI_U, "u"), (kVK_ANSI_I, "i"), (kVK_ANSI_P, "p"), (kVK_ANSI_L, "l"), (kVK_ANSI_J, "j"), (kVK_ANSI_K, "k"), (kVK_ANSI_N, "n"), (kVK_ANSI_M, "m")]
        for (code, key) in letters { map[UInt32(code)] = key }
        return map
    }()
    func menuLabel() -> String { label.isEmpty ? title : "\(title)     \(label)" }
}
