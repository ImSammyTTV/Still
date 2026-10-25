import SwiftUI
import ServiceManagement
import StillCore
import Carbon
import AVFoundation

struct MainView: View {
    @ObservedObject var library: Library
    @ObservedObject var recorder: Recorder
    @ObservedObject private var prefs = Preferences.shared
    @State private var shortcutSearch = ""
    @State private var cameraDevices: [AVCaptureDevice] = []
    @State private var audioDevices: [AVCaptureDevice] = []
    @State private var shortcuts = Shortcut.load()
    @State private var loginError: String?
    private let categories: [(String, String, Color)] = [
        ("General", "gearshape.fill", .gray), ("Shortcuts", "command", .gray), ("Quick Access", "rectangle.bottomthird.inset.filled", .green),
        ("Wallpaper", "photo.fill", .cyan), ("Screenshots", "camera.fill", .blue), ("Screen Recording", "video.fill", .pink),
        ("Annotate", "pencil.tip", .orange), ("Cloud", "icloud.fill", .blue), ("Advanced", "wand.and.stars", .purple)
    ]
    private var selected: String { categories.map(\.0).contains(library.page) || library.page == "About" ? library.page : "General" }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 11) { Image(systemName: "viewfinder").font(.system(size: 20)).frame(width: 32, height: 32).background(Color.accentColor.opacity(0.12), in: Circle()); VStack(alignment: .leading, spacing: 3) { Text("Still").font(.system(size: 12, weight: .semibold)); Text("Personal capture utility").font(.system(size: 10)).foregroundStyle(.secondary) } }.padding(.horizontal, 14).padding(.top, 58).padding(.bottom, 19)
                ForEach(categories, id: \.0) { category in
                    Button { library.page = category.0 } label: {
                        HStack(spacing: 10) { Image(systemName: category.1).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(width: 21, height: 21).background(category.2, in: RoundedRectangle(cornerRadius: 5)); Text(category.0); Spacer() }
                            .padding(.horizontal, 7).frame(height: 32).background(selected == category.0 ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).padding(.horizontal, 9)
                }
                Spacer()
                Button { library.page = "About" } label: { HStack(spacing: 10) { Image(systemName: "info.circle.fill").font(.system(size: 20)).foregroundStyle(.gray); Text("About"); Spacer() }.padding(7).frame(height: 32).background(selected == "About" ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain).padding(.horizontal, 9).padding(.bottom, 16)
            }.frame(width: 205).background(NativeMaterial(material: .sidebar)).overlay(alignment: .trailing) { Divider() }
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text(selected).font(.system(size: 13, weight: .semibold)); Spacer(); if selected == "Shortcuts" { TextField("Search shortcuts", text: $shortcutSearch).textFieldStyle(.roundedBorder).frame(width: 190) } }.padding(.horizontal, 18).padding(.top, 17).padding(.bottom, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 23) { content }.padding(.horizontal, 18).padding(.bottom, 22)
                }
                if let message = library.message { Text(message).font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 8) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }.font(.system(size: 12)).ignoresSafeArea()
        .alert("Settings couldn’t be updated", isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })) { Button("OK") { loginError = nil } } message: { Text(loginError ?? "") }
    }
    @ViewBuilder private var content: some View {
        switch selected {
        case "General": general
        case "Shortcuts": shortcutPage
        case "Quick Access": quickAccess
        case "Wallpaper": wallpaper
        case "Screenshots": screenshots
        case "Screen Recording": recording
        case "Annotate": annotate
        case "Cloud": CloudSettingsView(library: library)
        case "Advanced": advanced
        default: about
        }
    }
    private var general: some View {
        Group {
            section("App") {
                Toggle("Launch at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { do { try prefs.setLaunchAtLogin($0) } catch { loginError = error.localizedDescription } }))
                Toggle("Show menu bar icon", isOn: $prefs.showMenuBar).onChange(of: prefs.showMenuBar) { _, value in AppController.shared.setMenuBarVisible(value) }
                choice("Appearance", selection: $prefs.appearance) { Text("System Default").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.onChange(of: prefs.appearance) { _, _ in AppController.shared.applyAppearance() }
            }
            section("Capture") { Toggle("Hide desktop icons while capturing", isOn: $prefs.hideDesktop) }
            section("Sounds") { Toggle("Play sounds", isOn: $library.captureSound) }
            section("Export") {
                HStack { Text("Export location"); Spacer(); Text(library.exportFolder.isEmpty ? "Desktop" : URL(fileURLWithPath: library.exportFolder).lastPathComponent).foregroundStyle(.secondary); Button("Choose…") { chooseFolder() } }
                Text("Set the default save location used by the Quick Access Overlay, After Capture and Save actions.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            section("After Capture") {
                HStack { Text("Action").foregroundStyle(.secondary); Spacer(); Text("Screenshot").foregroundStyle(.secondary).frame(width: 85); Text("Recording").foregroundStyle(.secondary).frame(width: 75) }
                afterRow("Show Quick Access Overlay", image: $library.showPreview, video: $prefs.recordingPreview)
                afterRow("Copy file to clipboard", image: $library.autoCopy, video: $prefs.copyRecording)
                afterRow("Save", image: $prefs.saveAfterCapture)
                afterRow("Upload to Cloud & copy link", image: $prefs.autoUploadImages, video: $prefs.autoUploadVideos)
                afterRow("Open Annotate tool", image: $prefs.annotateAfterCapture)
                afterRow("Pin to the screen", image: $prefs.pinAfterCapture)
                HStack { Text("Open Video Editor"); Spacer(); Text("—").foregroundStyle(.secondary).frame(width: 85); Toggle("Open Video Editor", isOn: $prefs.openVideoEditor).labelsHidden().toggleStyle(.checkbox).frame(width: 75) }
            }
            if !library.permissionGranted {
                section("Permissions") { HStack { Text("Screen recording access is required.").foregroundStyle(.secondary); Spacer(); Button("Enable Capture…") { AppController.shared.requestPermission() } }; if let error = library.permissionError { Text(error).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }; Button("Refresh Permission Status") { AppController.shared.requestPermission() }.buttonStyle(.link) }
            }
            HStack { Button("All-In-One") { AppController.shared.showAllInOne() }; Button("Capture History") { AppController.shared.showHistory() }; Spacer(); Button("Try Annotate") { AppController.shared.demo() } }
        }
    }
    private var shortcutPage: some View {
        section("Keyboard Shortcuts") {
            ForEach(shortcuts.indices.filter { shortcutSearch.isEmpty || shortcuts[$0].title.localizedCaseInsensitiveContains(shortcutSearch) }, id: \.self) { index in
                HStack { Text(shortcuts[index].title); Spacer(); ShortcutField(shortcut: $shortcuts[index]) { saveShortcuts() }.frame(width: 156, height: 27); if shortcuts[index].keyCode != nil { Button { shortcuts[index].keyCode = nil; shortcuts[index].label = ""; saveShortcuts() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear \(shortcuts[index].title) shortcut") } }
            }
            HStack { Spacer(); Button("Reset Defaults") { shortcuts = Shortcut.defaults; saveShortcuts() } }
        }
    }
    private var quickAccess: some View {
        Group {
            section("Quick Access Overlay") {
                Toggle("Show after screenshot", isOn: $library.showPreview)
                Toggle("Show after recording", isOn: $prefs.recordingPreview)
                choice("Position", selection: $prefs.previewPosition) { Text("Bottom Left").tag("bottomLeft"); Text("Bottom Right").tag("bottomRight"); Text("Top Left").tag("topLeft"); Text("Top Right").tag("topRight") }
                HStack { Text("Size"); Slider(value: $prefs.previewWidth, in: 180...400, step: 10); Text("\(Int(prefs.previewWidth)) px").foregroundStyle(.secondary).frame(width: 48) }
                choice("Automatically close", selection: $prefs.previewTimeout) { Text("Never").tag(0.0); Text("5 seconds").tag(5.0); Text("10 seconds").tag(10.0); Text("30 seconds").tag(30.0); Text("60 seconds").tag(60.0) }
            }
            section("Swipe Gestures") {
                choice("Swipe left", selection: $prefs.previewSwipeLeft) { ForEach(["dismiss", "copy", "save", "edit", "upload"], id: \.self) { Text($0.capitalized).tag($0) } }
                choice("Swipe right", selection: $prefs.previewSwipeRight) { ForEach(["dismiss", "copy", "save", "edit", "upload"], id: \.self) { Text($0.capitalized).tag($0) } }
                Text("When an overlay has focus: Return opens it, ⌘C copies it, and Escape closes it.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            section("Actions") { Button("Restore Last Capture") { AppController.shared.restoreLastCapture() }; Button("Hide / Show All Overlays") { AppController.shared.toggleOverlays() } }
        }
    }
    private var wallpaper: some View {
        section("Desktop") {
            choice("Wallpaper", selection: $prefs.wallpaperMode) { Text("Desktop wallpaper").tag("desktop"); Text("Custom image").tag("image"); Text("Solid color").tag("color") }
            Text("Used to cover desktop icons without changing Finder’s settings and as the background for window screenshots.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if prefs.wallpaperMode == "image" { HStack { Text(prefs.wallpaperImage.isEmpty ? "No image selected" : URL(fileURLWithPath: prefs.wallpaperImage).lastPathComponent).lineLimit(1); Spacer(); Button("Choose…") { let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; if panel.runModal() == .OK, let url = panel.url { prefs.wallpaperImage = url.path } } } }
            if prefs.wallpaperMode == "color" { ColorPicker("Color", selection: Binding(get: { Color(hex: prefs.wallpaperColor) }, set: { color in if let c = NSColor(color).usingColorSpace(.sRGB) { prefs.wallpaperColor = String(format: "%02X%02X%02X", Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255)) } }), supportsOpacity: false) }
            Button("Toggle Desktop Icons") { AppController.shared.toggleDesktop() }
        }
    }
    private var screenshots: some View {
        Group {
            section("Screenshots") {
                choice("Image format", selection: $prefs.exportFormat) { Text("PNG").tag("png"); Text("JPEG").tag("jpg"); Text("TIFF").tag("tiff"); Text("HEIC").tag("heic") }
                TextField("File name", text: $prefs.filenamePattern)
                Text("Available tokens: {date}, {time}, {width}, {height}").font(.system(size: 10)).foregroundStyle(.secondary)
                Toggle("Capture mouse cursor", isOn: $prefs.includeCursor)
                Toggle("Freeze screen when taking a screenshot", isOn: $prefs.freezeScreen)
            }
            section("Window Screenshots") {
                Toggle("Include background", isOn: $prefs.windowBackground)
                HStack { Text("Padding"); Slider(value: $prefs.windowPadding, in: 0...160, step: 4) }
                Toggle("Capture window shadow", isOn: $prefs.windowShadow)
            }
            section("Crosshair") {
                choice("Crosshair Mode", selection: $prefs.crosshair) { Text("Disabled").tag("disabled"); Text("Cross").tag("cross"); Text("Full Screen").tag("full") }
                Toggle("Show magnifier", isOn: $prefs.magnifier)
            }
        }
    }
    private var recording: some View {
        Group {
            section("Video") {
                choice("Quality", selection: $prefs.recordingQuality) { ForEach(VideoQuality.allCases) { Text($0.title).tag($0.rawValue) } }
                choice("Frame rate", selection: $prefs.recordingFPS) { ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) } }
                choice("Max resolution", selection: $prefs.recordingResolution) { Text("Original").tag(0); Text("1080p").tag(1920); Text("1440p").tag(2560); Text("4K").tag(3840) }
                Toggle("Show cursor", isOn: $prefs.recordingCursor)
            }
            section("Audio") { Toggle("Record system audio", isOn: $library.systemAudio); Toggle("Record microphone", isOn: $library.microphoneAudio); choice("Microphone", selection: $prefs.recordingMicrophoneID) { Text("System Default").tag(""); ForEach(audioDevices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } } }.onAppear { audioDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices }
            section("Focus & Recording Automation") {
                Toggle("Run Shortcuts when recording starts and stops", isOn: $prefs.recordingAutomation)
                TextField("Start shortcut name", text: $prefs.recordingStartShortcut).textFieldStyle(.roundedBorder)
                TextField("End shortcut name", text: $prefs.recordingEndShortcut).textFieldStyle(.roundedBorder)
                Text("To control Do Not Disturb, create a shortcut that turns Focus on and a second shortcut that restores it. Enter their names here. Still runs only the shortcuts you configure.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Shortcuts") { if let url = URL(string: "shortcuts://") { NSWorkspace.shared.open(url) } }
            }
            section("GIF") {
                choice("Frame rate", selection: $prefs.gifFPS) { ForEach([5, 10, 12, 15, 24], id: \.self) { Text("\($0) fps").tag($0) } }
                choice("Resolution", selection: $prefs.gifWidth) { ForEach([480, 640, 800, 1280], id: \.self) { Text("\($0) × auto").tag($0) } }
            }
            section("Capture Clicks") {
                Toggle("Show clicks", isOn: $prefs.recordingClicks)
                ColorPicker("Color", selection: hexColor($prefs.clickColor), supportsOpacity: false)
                HStack { Text("Size"); Slider(value: $prefs.clickSize, in: 0.4...2.5) }
                choice("Style", selection: $prefs.clickStyle) { Text("Outline").tag("outline"); Text("Filled").tag("filled") }
                Toggle("Animate clicks", isOn: $prefs.clickAnimated)
            }
            section("Capture Keystrokes") {
                Toggle("Show keystrokes", isOn: $prefs.recordingKeys); Toggle("Show only command keys", isOn: $prefs.recordingCommandKeysOnly)
                choice("Style", selection: $prefs.keysStyle) { Text("Dark").tag("dark"); Text("Light").tag("light") }
                HStack { Text("Size"); Slider(value: $prefs.keysSize, in: 0.5...2) }
                choice("Position", selection: $prefs.keysPosition) { ForEach(["topLeft", "topCenter", "topRight", "bottomLeft", "bottomCenter", "bottomRight"], id: \.self) { Text($0.replacingOccurrences(of: "top", with: "Top ").replacingOccurrences(of: "bottom", with: "Bottom ")).tag($0) } }
            }
            section("Camera") { Toggle("Record camera", isOn: $prefs.recordingCamera); choice("Camera", selection: $prefs.recordingCameraID) { Text("System Default").tag(""); ForEach(cameraDevices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } }; Toggle("Fullscreen camera", isOn: $prefs.cameraFullscreen); Toggle("Mirror camera", isOn: $prefs.cameraMirror); choice("Position", selection: $prefs.cameraPosition) { ForEach(["topLeft", "topRight", "bottomLeft", "bottomRight"], id: \.self) { Text($0.replacingOccurrences(of: "top", with: "Top ").replacingOccurrences(of: "bottom", with: "Bottom ")).tag($0) } }; choice("Shape", selection: $prefs.recordingCameraShape) { Text("Circle").tag("circle"); Text("Rounded rectangle").tag("rounded") }; HStack { Text("Size"); Slider(value: $prefs.recordingCameraSize, in: 100...360, step: 10) } }.onAppear { cameraDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices }
        }
    }
    private var annotate: some View {
        Group {
            section("Default Tool") { choice("Tool", selection: $prefs.annotateDefaultTool) { ForEach(MarkTool.allCases.filter { $0 != .image && $0 != .crop }, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }; HStack { Text("Stroke width"); Slider(value: $prefs.annotateDefaultWidth, in: 2...24, step: 1); Text("\(Int(prefs.annotateDefaultWidth)) px").foregroundStyle(.secondary) } }
            section("Editor") { Text("Annotations stay editable in capture history. Export an editable .stillshot project to continue on another Mac. Image exports flatten and remove covered pixels.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true); Button("Open Sample Image") { AppController.shared.demo() }; Button("Open Image or Project…") { AppController.shared.importImage() } }
        }
    }
    private var cloud: some View {
        Group {
            section("Hosting") {
                Text("Connect your own Still Cloud server to upload captures and copy shareable links.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Server URL", text: $prefs.cloudEndpoint).textFieldStyle(.roundedBorder)
                choice("Default link expiration", selection: $prefs.cloudExpiry) { Text("Never").tag(0); Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30) }
                Text("No file is uploaded until you use an upload action. Connect your own Still server to share captures.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var advanced: some View {
        Group {
            section("Capture History") { choice("Keep history", selection: $prefs.retentionDays) { Text("Forever").tag(0); Text("1 day").tag(1); Text("3 days").tag(3); Text("1 week").tag(7); Text("1 month").tag(30) }; Button("Open Capture History") { AppController.shared.showHistory() }; Button("Open Storage Folder") { NSWorkspace.shared.open(library.root) } }
            section("Text Recognition") {
                choice("Language", selection: $prefs.ocrLanguage) { Text("Automatically Detect Language").tag("auto"); Text("English").tag("en-US"); Text("Chinese, Simplified").tag("zh-Hans"); Text("Chinese, Traditional").tag("zh-Hant"); Text("French").tag("fr-FR"); Text("German").tag("de-DE"); Text("Japanese").tag("ja-JP"); Text("Korean").tag("ko-KR"); Text("Spanish").tag("es-ES"); Text("Portuguese").tag("pt-BR") }
                Toggle("Keep line breaks", isOn: $prefs.ocrLineBreaks)
            }
            section("All-In-One") { Toggle("Remember last selection", isOn: $prefs.rememberSelection) }
            section("Pinned Screenshots") { Toggle("Rounded corners", isOn: $prefs.pinRounded); Toggle("Shadow", isOn: $prefs.pinShadow); Toggle("Border", isOn: $prefs.pinBorder) }
            section("API") { Toggle("Allow URL scheme API", isOn: $prefs.allowURLScheme) }
            section("Permissions") { Button("Screen Recording Settings…") { AppController.shared.openPermissionSettings() }; Button("Refresh Permissions") { AppController.shared.requestPermission() } }
        }
    }
    private var about: some View {
        VStack(spacing: 18) {
            Image(systemName: "viewfinder").font(.system(size: 60, weight: .light)).foregroundStyle(Color.accentColor)
            Text("Still").font(.system(size: 25, weight: .bold)); Text("Native capture for your Mac").foregroundStyle(.secondary)
            Text("Version 1.0 · Independent implementation").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Open Feature Coverage") { if let path = Bundle.main.resourceURL?.appendingPathComponent("Documentation/FEATURES.md") { NSWorkspace.shared.open(path) } }
            Button("Quit Still") { NSApp.terminate(nil) }
        }.frame(maxWidth: .infinity).padding(.top, 55)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 11, weight: .semibold)); VStack(alignment: .leading, spacing: 0) { content().padding(.horizontal, 10).padding(.vertical, 10) }.frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)) }.toggleStyle(PreferenceToggleStyle()).controlSize(.small)
    }
    private func afterRow(_ title: String, image: Binding<Bool>, video: Binding<Bool>? = nil) -> some View { HStack { Text(title); Spacer(); Toggle(title, isOn: image).labelsHidden().toggleStyle(.checkbox).frame(width: 85); if let video { Toggle(title, isOn: video).labelsHidden().toggleStyle(.checkbox).frame(width: 75) } else { Text("—").foregroundStyle(.secondary).frame(width: 75) } } }
    private func choice<Value: Hashable, Content: View>(_ title: String, selection: Binding<Value>, @ViewBuilder content: () -> Content) -> some View { HStack { Text(title); Spacer(minLength: 12); Picker(title, selection: selection, content: content).labelsHidden().fixedSize().frame(maxWidth: 270, alignment: .trailing) } }
    private func chooseFolder() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; if panel.runModal() == .OK, let url = panel.url { library.exportFolder = url.path } }
    private func saveShortcuts() { if let data = try? JSONEncoder().encode(shortcuts) { UserDefaults.standard.set(data, forKey: "shortcuts"); AppController.shared.reloadShortcuts() } }
}
struct PreferenceToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { HStack { configuration.label; Spacer(minLength: 16); Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) } }
}

struct ShortcutField: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    var changed: () -> Void
    func makeNSView(context: Context) -> ShortcutButton { let button = ShortcutButton(); button.bezelStyle = .rounded; return button }
    func updateNSView(_ view: ShortcutButton, context: Context) { if !view.recording { view.title = shortcut.label.isEmpty ? "Record shortcut" : shortcut.label }; view.received = { code, flags, label in shortcut.keyCode = code; shortcut.modifiers = flags; shortcut.label = label; changed() } }
}
final class ShortcutButton: NSButton {
    var recording = false
    var received: ((UInt32, UInt32, String) -> Void)?
    private var monitor: Any?
    override func mouseDown(with event: NSEvent) {
        recording = true; title = "Press shortcut…"; window?.makeFirstResponder(self)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.keyCode != 53 {
                let flags = event.modifierFlags
                guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
                var carbon: UInt32 = 0; var label = ""
                if flags.contains(.control) { carbon |= UInt32(controlKey); label += "⌃" }
                if flags.contains(.option) { carbon |= UInt32(optionKey); label += "⌥" }
                if flags.contains(.shift) { carbon |= UInt32(shiftKey); label += "⇧" }
                if flags.contains(.command) { carbon |= UInt32(cmdKey); label += "⌘" }
                label += event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
                self.received?(UInt32(event.keyCode), carbon, label); self.title = label
            }
            self.recording = false; if let monitor = self.monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
