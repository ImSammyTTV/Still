import AppKit
import Carbon
import SwiftUI
import Combine
import StillCore
import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureMode { case area, window, screen, text }

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppController!
    let library = Library()
    let recorder = Recorder()
    private let selection = CaptureSelection()
    private let scrolling = ScrollingSession()
    private var cloudWindows: [UUID: NSWindow] = [:]
    private var cloudUploads: [UUID: CloudUploadModel] = [:]
    private var historyPanel: NSPanel?
    private var lastPreviewItem: CaptureItem?
    private var previewPanels: [UUID: NSPanel] = [:]
    private var previewOrder: [UUID] = []
    private var overlaysHidden = false
    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let hotkeys = Hotkeys()
    private var captureProcess: Process?
    private var editors: [UUID: NSWindow] = [:]
    private var videoModels: [UUID: VideoEditorModel] = [:]
    private var editorModels: [UUID: EditorModel] = [:]
    private var preview: NSPanel?
    private var pins: [UUID: NSPanel] = [:]
    private var recordingHUD: NSPanel?
    private var cameraPanel: NSPanel?
    private var recordingSetupPanel: NSPanel?
    private var recordingBorder: NSPanel?
    private var forceVideoEditor = false
    private var subscriptions = Set<AnyCancellable>()
    private var lastExternalApp: NSRunningApplication?
    /// Set while a capture started from a still:// link is in progress.
    private var urlCapture = false
    /// True while a finished recording is being exported and added to the library.
    private(set) var preparingRecording = false
    private var workspaceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared = self
        NSApp.servicesProvider = self
        NSApp.setActivationPolicy(.accessory)
        applyAppearance()
        setupMenu()
        hotkeys.handler = { [weak self] id in
            Task { @MainActor in
                switch id {
                case 1: self?.capture(.area)
                case 2: self?.capture(.window)
                case 3: self?.capture(.screen)
                case 4: self?.toggleRecording()
                case 5: self?.showAllInOne()
                case 6: self?.capturePrevious()
                case 7: self?.showAllInOne(purpose: .scroll)
                case 8: self?.capture(.text)
                case 9: self?.showHistory()
                case 10: self?.restoreLastCapture()
                case 11: self?.toggleDesktop()
                case 12: self?.toggleOverlays()
                case 13: self?.showClipboardMenu()
                default: break
                }
            }
        }
        hotkeys.register()
        setMenuBarVisible(Preferences.shared.showMenuBar)
        if !hotkeys.unavailable.isEmpty { library.toast("Some shortcuts are already in use. Capture buttons still work.") }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                Task { @MainActor in self?.lastExternalApp = app }
            }
        }
        recorder.onComplete = { [weak self] url in
            guard let self else { return }
            DesktopCover.shared.endCapture()
            self.recordingHUD?.close(); self.recordingHUD = nil
            let metadata = self.recorder.completedMetadata, camera = self.recorder.completedCameraURL
            let showEditor = self.forceVideoEditor || Preferences.shared.openVideoEditor; self.forceVideoEditor = false
            self.library.busy = true; self.preparingRecording = true; self.showCopyToast("Preparing your recording…")
            Task {
                var keepOriginal = false
                defer { self.library.busy = false; self.preparingRecording = false; if !keepOriginal { try? FileManager.default.removeItem(at: url) }; if let camera { try? FileManager.default.removeItem(at: camera) }; self.restoreOverlays() }
                let gif = Preferences.shared.recordingFormat == "gif"
                let exported = FileManager.default.temporaryDirectory.appendingPathComponent("Still-finished-\(UUID()).\(gif ? "gif" : "mp4")")
                defer { try? FileManager.default.removeItem(at: exported) }
                do {
                    var settings = metadata.presentation ?? Preferences.shared.recordingPresentation
                    settings.cursorScale = metadata.defaultShowCursor ? 1 : 0; settings.showClicks = metadata.defaultShowClicks; settings.showKeystrokes = metadata.defaultShowKeystrokes
                    settings.cameraShape = Preferences.shared.recordingCameraShape
                    let prepared = try await VideoEngine.prepare(url: url, settings: settings, metadata: metadata, cameraURL: camera)
                    if gif { try await VideoEngine.gif(prepared, to: exported, fps: Preferences.shared.gifFPS, width: Preferences.shared.gifWidth) }
                    else { try await VideoEngine.export(prepared, to: exported) }
                    let item = try self.library.add(file: exported, title: self.captureTitle("Recording"), video: true)
                    try self.library.attachVideoSource(item, source: url); try self.library.saveRecordingMetadata(item, metadata: metadata, camera: camera)
                    if Preferences.shared.copyRecording { self.library.copy(item) }
                    if Preferences.shared.recordingPreview { self.showPreview(item) }
                    if Preferences.shared.autoUploadVideos { self.upload(item) }
                    if showEditor { self.openVideoEditor(item) }
                } catch {
                    if let item = try? self.library.add(file: url, title: self.captureTitle("Original recording"), video: true) {
                        try? self.library.saveRecordingMetadata(item, metadata: metadata, camera: camera)
                        self.showError("The original recording was kept", "The effects export failed: \(error.localizedDescription). You can open the original in Capture History.")
                    } else {
                        // The library couldn't take it either (a full disk, say). Never delete the only copy:
                        // move it somewhere the user can find it instead.
                        let rescue = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent("\(self.captureTitle("Recording")).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
                        if (try? FileManager.default.moveItem(at: url, to: rescue)) != nil {
                            self.showError("Your recording was saved to the Desktop", "Still couldn’t finish it (\(error.localizedDescription)), so the original was moved to \(rescue.lastPathComponent) on your Desktop.")
                        } else {
                            self.showError("Your recording couldn’t be saved", "\(error.localizedDescription). The original is still at \(url.path); copy it somewhere safe before restarting your Mac.")
                            keepOriginal = true
                        }
                    }
                }
            }
        }
        recorder.onWarning = { [weak self] text in self?.library.toast(text) }
        recorder.onError = { [weak self] text in DesktopCover.shared.endCapture(); self?.recordingHUD?.close(); self?.showError("Recording couldn’t start", text) }
        recorder.onCancel = { [weak self] in DesktopCover.shared.endCapture(); self?.restoreOverlays() }
        recorder.$recording.sink { [weak self] active in
            RecordingAutomation.shared.update(recording: active) { [weak self] in self?.library.toast($0) }
            DispatchQueue.main.async {
                self?.setMenuBarStopButton(active)
                if active { self?.showRecordingHUD() }
            }
        }.store(in: &subscriptions)
        recorder.$elapsed.map { Int($0) }.removeDuplicates().sink { [weak self] seconds in
            guard let self, self.recorder.recording else { return }
            self.statusItem.button?.title = String(format: " %d:%02d", seconds/60, seconds%60)
        }.store(in: &subscriptions)
        recorder.$cameraSession.sink { [weak self] session in
            DispatchQueue.main.async {
                guard let self else { return }; self.cameraPanel?.close(); self.cameraPanel = nil
                guard let session, let screen = NSScreen.main else { return }
                let size = Preferences.shared.recordingCameraSize
                let panel = NSPanel(contentRect: CGRect(x: screen.visibleFrame.maxX-size-24, y: screen.visibleFrame.minY+80, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
                panel.contentView = NSHostingView(rootView: CameraBubble(session: session).clipShape(RoundedRectangle(cornerRadius: Preferences.shared.recordingCameraShape == "circle" ? size/2 : 18)))
                panel.orderFrontRegardless(); self.cameraPanel = panel
            }
        }.store(in: &subscriptions)
        selection.onCancel = { [weak self] in self?.library.busy = false; DesktopCover.shared.endCapture(); self?.restoreOverlays(); self?.returnFocus() }
        selection.onError = { [weak self] error in self?.library.busy = false; DesktopCover.shared.endCapture(); self?.showError("Capture failed", error.localizedDescription) }
        selection.onWindowSelected = { [weak self] id, screen, rect in
            guard let self else { return }
            self.library.busy = false; DesktopCover.shared.endCapture()
            self.showRecordingSetup(screen: screen, rect: rect, windowID: id)
        }
        selection.onSelected = { [weak self] image, screen, rect, purpose in
            guard let self else { return }
            if purpose == .scroll { self.scrolling.start(first: image, screen: screen, rect: rect) }
            else if purpose == .recording { self.library.busy = false; DesktopCover.shared.endCapture(); self.showRecordingSetup(screen: screen, rect: rect) }
            else { Task { await self.completeScreenshot(image, text: purpose == .text); self.library.busy = false; DesktopCover.shared.endCapture(); self.restoreOverlays(); self.returnFocus() } }
        }
        scrolling.onComplete = { [weak self] image in Task { await self?.completeScreenshot(image); self?.library.busy = false; DesktopCover.shared.endCapture(); self?.restoreOverlays() } }
        scrolling.onCancel = { [weak self] in self?.library.busy = false; DesktopCover.shared.endCapture(); self?.restoreOverlays() }
        // A menu bar app: only open Settings the first time, so launches at login stay out of the way.
        if !UserDefaults.standard.bool(forKey: "studioSetupComplete") { showMain() }
        if CommandLine.arguments.contains("--editor-demo") { demo() }
        DispatchQueue.main.asyncAfter(deadline: .now()+1) { [weak self] in self?.selection.prewarm(); self?.checkSystemScreenshotShortcut() }
        Updater.shared.start()
        ClipboardHistory.shared.start()
        // After an update, ask macOS to re-read Still's right-click Services.
        if UserDefaults.standard.string(forKey: "servicesVersion") != Updater.shared.currentVersion {
            NSUpdateDynamicServices(); UserDefaults.standard.set(Updater.shared.currentVersion, forKey: "servicesVersion")
        }
        // Recordings rescued after a failure wait in Recovery; say so rather than leave them forgotten.
        let recovery = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Still/Recovery")
        if let rescued = try? FileManager.default.contentsOfDirectory(atPath: recovery.path).filter({ !$0.hasPrefix(".") }), !rescued.isEmpty {
            library.toast("\(rescued.count) recovered recording\(rescued.count == 1 ? " is" : "s are") waiting in \(recovery.path)")
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if preparingRecording {
            let alert = NSAlert(); alert.messageText = "Still is saving your recording"
            alert.informativeText = "Wait a moment for it to finish, then quit. Quitting now would lose the recording."
            alert.runModal(); return .terminateCancel
        }
        if recorder.recording || recorder.stopping {
            let alert = NSAlert(); alert.messageText = "A recording is in progress"
            alert.informativeText = "Stop the recording before quitting so Still can finish saving the video."
            alert.addButton(withTitle: "Stop Recording"); alert.addButton(withTitle: "Keep Recording")
            if alert.runModal() == .alertFirstButtonReturn { recorder.stop() }
            return .terminateCancel
        }
        if editorModels.values.contains(where: { $0.dirty }) || videoModels.values.contains(where: { $0.dirty || $0.exporting }) {
            let alert = NSAlert(); alert.messageText = "Quit with unsaved edits?"
            alert.informativeText = "Your original captures stay in the library. Unsaved annotations will be lost."
            alert.addButton(withTitle: "Keep Editing"); alert.addButton(withTitle: "Quit Without Saving")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        for model in videoModels.values { model.close() }
        captureProcess?.interrupt()
        selection.close(); scrolling.cancel(); DesktopCover.shared.reset(); LocalCloudServer.shared.stop()
        return .terminateNow
    }
    private func setupMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Still", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Still", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Still", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; main.addItem(app)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        edit.submenu = editMenu; main.addItem(edit)
        let captureItem = NSMenuItem(); let captureMenu = NSMenu(title: "Capture")
        for (title, action) in [("Capture Bar", #selector(allInOne)), ("Capture Area", #selector(captureArea)), ("Capture Window", #selector(captureWindow)), ("Capture Full Screen", #selector(captureScreen)), ("Capture Text", #selector(captureText)), ("Scrolling Capture", #selector(scrollingCapture)), ("Record / Stop Recording", #selector(record)), ("Capture Previous Area", #selector(capturePrevious))] {
            let entry = NSMenuItem(title: title,action: action,keyEquivalent: ""); entry.target = self; captureMenu.addItem(entry)
        }
        captureMenu.addItem(.separator())
        for (index,screen) in NSScreen.screens.enumerated() { let entry = NSMenuItem(title: "Capture \(screen.localizedName)",action: #selector(captureDisplay(_:)),keyEquivalent: ""); entry.target = self; entry.tag = index; captureMenu.addItem(entry) }
        captureMenu.addItem(.separator())
        let timed = NSMenuItem(title: "Timed Capture",action: nil,keyEquivalent: ""), timers = NSMenu()
        for delay in [3,5,10] { let entry = NSMenuItem(title: "Capture Area in \(delay) Seconds",action: #selector(timedCapture(_:)),keyEquivalent: ""); entry.tag = delay; entry.target = self; timers.addItem(entry) }; timed.submenu = timers; captureMenu.addItem(timed)
        captureItem.submenu = captureMenu; main.addItem(captureItem)
        let window = NSMenuItem(); let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Capture History", action: #selector(showHistory), keyEquivalent: "0")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.submenu = windowMenu; main.addItem(window)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Studio.menuBarIcon()
        menu = NSMenu()
        menu.addItem(withTitle: "Capture Bar", action: #selector(allInOne), keyEquivalent: "")
        menu.addItem(.separator())
        let shortcuts = Shortcut.load()
        for (id, title, action) in [(UInt32(1), "Capture Area", #selector(captureArea)), (2, "Capture Window", #selector(captureWindow)), (3, "Capture Full Screen", #selector(captureScreen)), (4, "Record / Stop Recording", #selector(record)), (8, "Capture Text", #selector(captureText))] {
            let label = shortcuts.first(where: { $0.id == id })?.label ?? ""
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.tag = Int(id); menu.addItem(item)
            _ = label
        }
        menu.addItem(.separator())
        let clipboard = NSMenuItem(title: "Clipboard History", action: nil, keyEquivalent: ""); clipboardMenu.delegate = self; clipboard.submenu = clipboardMenu; menu.addItem(clipboard)
        menu.addItem(withTitle: "Open Image…", action: #selector(importImage), keyEquivalent: "")
        menu.addItem(withTitle: "Capture Previous Area", action: #selector(capturePrevious), keyEquivalent: "")
        menu.addItem(withTitle: "Scrolling Capture", action: #selector(scrollingCapture), keyEquivalent: "")
        menu.addItem(withTitle: "Capture History", action: #selector(showHistory), keyEquivalent: "")
        menu.addItem(withTitle: "Restore Last Capture", action: #selector(restoreLastCapture), keyEquivalent: "")
        menu.addItem(withTitle: "Show Last Link as QR Code", action: #selector(showLastLinkQR), keyEquivalent: "")
        menu.addItem(withTitle: "Hide / Show Overlays", action: #selector(toggleOverlays), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle Desktop Icons", action: #selector(toggleDesktop), keyEquivalent: "")
        menu.addItem(withTitle: "Unlock Pinned Screenshots", action: #selector(unlockPins), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: "")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Still", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp; menu.addItem(quit)
        for item in menu.items where item.target == nil { item.target = self }
        decorateMenu()
        statusItem.menu = menu; menu.delegate = self
    }
    /// Closes Still's menu bar menu (and its submenus) if it's open, e.g. when a capture starts from a shortcut.
    func closeMenus() { menu?.cancelTrackingWithoutAnimation(); clipboardMenu.cancelTrackingWithoutAnimation() }
    @objc func openMain() { showMain() }
    @objc func settings() { library.page = "General"; showMain() }
    @objc func allInOne() { showAllInOne() }
    @objc func scrollingCapture() { showAllInOne(purpose: .scroll) }
    @objc func timedCapture(_ sender: NSMenuItem) { capture(.area,delay: sender.tag) }
    @objc func captureDisplay(_ sender: NSMenuItem) {
        guard NSScreen.screens.indices.contains(sender.tag), !library.busy, !recorder.recording else { return }
        let screen = NSScreen.screens[sender.tag]; library.busy = true; hideForCapture(); DesktopCover.shared.beginCapture()
        Task {
            defer { library.busy = false; DesktopCover.shared.endCapture(); restoreOverlays() }
            do { try await Task.sleep(for: .milliseconds(200)); await completeScreenshot(try await ScreenCaptureAPI.image(screen: screen)) }
            catch { showError("Capture failed", error.localizedDescription) }
        }
    }
    @objc func captureArea() { capture(.area) }
    @objc func captureWindow() { capture(.window) }
    @objc func captureScreen() { capture(.screen) }
    @objc func captureText() { capture(.text) }
    @objc func record() { toggleRecording() }
    /// While recording, the menu bar icon becomes a red stop button with the timer: one click stops and saves.
    private func setMenuBarStopButton(_ recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            statusItem.menu = nil
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
            button.imagePosition = .imageLeading
            button.title = " 0:00"
            button.contentTintColor = .systemRed
            button.target = self; button.action = #selector(stopRecordingFromMenuBar)
            button.toolTip = "Stop recording"
            statusItem.isVisible = true
        } else {
            button.image = Studio.menuBarIcon()
            button.title = ""; button.contentTintColor = nil
            button.action = nil; button.toolTip = nil
            statusItem.menu = menu
            setMenuBarVisible(Preferences.shared.showMenuBar)
        }
    }
    @objc func stopRecordingFromMenuBar() { if recorder.recording { recorder.stop() } }
    // MARK: Clipboard history
    let clipboardMenu = NSMenu(title: "Clipboard History")
    private var clipboardReturnApp: NSRunningApplication?
    func fillClipboardMenu(_ target: NSMenu, numbered: Bool) {
        target.removeAllItems()
        for item in ClipboardHistory.shared.menuItems(target: self, action: #selector(chooseClipboardItem(_:)), numbered: numbered) { target.addItem(item) }
        target.addItem(.separator())
        let clear = NSMenuItem(title: "Clear History", action: #selector(clearClipboardHistory), keyEquivalent: ""); clear.target = self
        clear.isEnabled = !ClipboardHistory.shared.items.isEmpty; target.addItem(clear)
    }
    /// ⇧⌘V: the history pops up at the pointer; 1–9 and 0 pick the first ten.
    func showClipboardMenu() {
        let front = NSWorkspace.shared.frontmostApplication
        clipboardReturnApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastExternalApp : front
        let popup = NSMenu(title: "Clipboard History")
        let header = NSMenuItem(title: "Clipboard History", action: nil, keyEquivalent: ""); header.isEnabled = false; popup.addItem(header)
        let items = NSMenu(); fillClipboardMenu(items, numbered: true)
        for item in items.items { items.removeItem(item); popup.addItem(item) }
        NSApp.activate(ignoringOtherApps: true)
        popup.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    @objc func chooseClipboardItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let item = ClipboardHistory.shared.items.first(where: { $0.id == id }) else { return }
        let target = clipboardReturnApp; clipboardReturnApp = nil
        ClipboardHistory.shared.choose(item, returnTo: target)
        if !ClipboardHistory.shared.pasteAutomatically { target?.activate() }
    }
    @objc func clearClipboardHistory() { ClipboardHistory.shared.clear() }

    @objc func checkForUpdates() { Updater.shared.check(manual: true) }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Still", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", .credits: NSAttributedString(string: "A personal capture studio for your Mac.\nBuilt with Swift, AppKit & SwiftUI.\nAll captures and text recognition stay on your Mac.")])
    }
    func showMain() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 729, height: 594), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Still Settings"; window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true; window.backgroundColor = .windowBackgroundColor
            window.minSize = NSSize(width: 700, height: 560); window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SetupRootView(library: library, recorder: recorder).tint(Studio.accent))
            host.sizingOptions = []
            window.contentView = Studio.glass(host, in: window)
            window.center(); window.setFrameAutosaveName("StillPreferences"); mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if CGPreflightScreenCaptureAccess() { library.permissionGranted = true }
    }
    func requestPermission() {
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                library.permissionGranted = true; library.permissionError = nil; library.toast("Screen access is ready")
            } catch {
                library.permissionGranted = false
                let native = error as NSError
                library.permissionError = "\(native.localizedDescription) (\(native.domain) \(native.code))"
                library.toast("Add /Applications/Still.app in Screen Recording settings, then enable it.")
                openPermissionSettings()
            }
        }
    }
    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func capture(_ mode: CaptureMode, delay: Int = 0, windowID: CGWindowID? = nil) {
        guard !library.busy, !recorder.recording, !recorder.choosing, !recorder.stopping else { library.toast("Finish the current capture or recording first"); return }
        if mode == .area || mode == .text { showAllInOne(purpose: mode == .text ? .text : .screenshot, delay: delay); return }
        library.busy = true
        let restoreOnCancel = mainWindow?.isVisible == true
        let previous = NSWorkspace.shared.frontmostApplication
        if previous?.bundleIdentifier != Bundle.main.bundleIdentifier { lastExternalApp = previous }
        hideForCapture(); lastExternalApp?.activate()
        DesktopCover.shared.beginCapture()
        Task {
            guard await CaptureCountdown.run(seconds: delay) else { library.busy = false; DesktopCover.shared.endCapture(); restoreOverlays(); return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Still-\(UUID()).png")
            defer {
                library.busy = false; captureProcess = nil; try? FileManager.default.removeItem(at: file)
                DesktopCover.shared.endCapture(); restoreOverlays()
            }
            var args = ["-t", "png"]
            if mode == .screen, Preferences.shared.includeCursor { args.append("-C") }
            if !library.captureSound { args.append("-x") }
            switch mode {
            case .area, .text: args += ["-i", "-s"]
            case .window: args += windowID.map { ["-l\($0)"] } ?? ["-i", "-w"]; if !Preferences.shared.windowShadow { args.append("-o") }
            case .screen: args += ["-m"]
            }
            args.append(file.path)
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                library.permissionGranted = true; library.permissionError = nil
                _ = try await runCapture(args)
                guard let image = ImageRenderer.load(file) else {
                    if restoreOnCancel { showMain() }
                    return
                }
                var finalImage = image
                if mode == .window, Preferences.shared.windowBackground {
                    let background = DesktopCover.shared.backgroundData(for: NSScreen.main)
                    finalImage = try ImageRenderer.render(image, frame: .midnight, padding: Int(Preferences.shared.windowPadding), customBackground: background)
                }
                await completeScreenshot(finalImage)
            } catch { showError("Capture failed", error.localizedDescription) }
        }
    }
    private func runCapture(_ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); process.arguments = arguments
            process.standardError = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
            captureProcess = process
            do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
    }
    func toggleRecording() {
        if recorder.recording { recorder.stop(); return }
        guard !library.busy, !recorder.stopping, !recorder.choosing else { return }
        hideForCapture(); lastExternalApp?.activate()
        showRecordingSetup()
    }
    func openItem(_ item: CaptureItem) {
        if item.isVideo { openVideoEditor(item) }
        else if let image = ImageRenderer.load(library.url(item)) { openEditor(image: image, item: item) }
    }
    func openEditor(image: CGImage, item: CaptureItem? = nil, recognize: Bool = false, isSample: Bool = false) {
        if let item, let window = editors[item.id] { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let id = item?.id ?? UUID()
        let model = EditorModel(image: image, item: item, library: library, isSample: isSample)
        if let item, let project = library.project(item) { model.restore(project) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = item?.title ?? "Still — Annotate"; window.minSize = NSSize(width: 1080, height: 560)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.delegate = self; window.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        window.contentView = Studio.glass(NSHostingView(rootView: EditorView(model: model)), in: window); window.center()
        editors[id] = window; editorModels[id] = model
        // Close the newest preview properly, so later captures don't bring it back.
        if let preview, let id = previewPanels.first(where: { $0.value === preview })?.key { dismissPreview(id) } else { preview?.close() }
        preview = nil
        NSApp.unhideWithoutActivation(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if recognize { model.recognize() }
    }
    func rekeyEditor(_ model: EditorModel) {
        guard let item = model.item, let oldID = editorModels.first(where: { $0.value === model })?.key, oldID != item.id, let window = editors[oldID] else { return }
        editors[oldID] = nil; editorModels[oldID] = nil
        editors[item.id] = window; editorModels[item.id] = model; window.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
    }
    func upload(_ item: CaptureItem) {
        presentUpload(file: library.url(item), item: item, title: item.title)
    }
    func uploadEditor(_ model: EditorModel) {
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try ImageRenderer.data(try model.flattened()).write(to: file, options: .atomic)
            presentUpload(file: file, item: nil, title: model.item?.title ?? "Screenshot", temporary: true)
        } catch { model.error = error.localizedDescription }
    }
    private func presentUpload(file: URL, item: CaptureItem?, title: String, temporary: Bool = false) {
        if Preferences.shared.cloudProvider == "icloud" {
            defer { if temporary { try? FileManager.default.removeItem(at: file) } }
            do { try ICloudDrive.save(file, title: title); showCopyToast("Saved to iCloud Drive") }
            catch { showError("Couldn’t save to iCloud Drive", error.localizedDescription) }
            return
        }
        let usesDrive = Preferences.shared.cloudProvider == "drive"
        guard usesDrive ? GoogleDrive.refreshToken != nil : !Preferences.shared.cloudEndpoint.isEmpty else {
            if temporary { try? FileManager.default.removeItem(at: file) }
            library.page = "Cloud"; showMain(); library.toast(usesDrive ? "Connect Google Drive first" : "Connect a Cloud server first"); return
        }
        let id = UUID(), model = CloudUploadModel(file: file, item: item, library: library, title: title, temporary: temporary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 390), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = usesDrive ? "Upload to Google Drive" : "Upload to Cloud"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CloudUploadView(model: model)); window.center()
        cloudWindows[id] = window; cloudUploads[id] = model
        model.completed = { [weak self, weak window] in window?.close(); self?.cloudWindows[id] = nil; self?.cloudUploads[id] = nil }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if !Preferences.shared.askUploadOptions && !NSEvent.modifierFlags.contains(.option) { model.upload() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return true }
        if let video = videoModels[id] {
            if video.exporting { library.toast("Finish or cancel the video export before closing"); return false }
            if video.dirty {
                let alert = NSAlert(); alert.messageText = "Save video edits?"; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard Edits"); alert.addButton(withTitle: "Cancel")
                let response = alert.runModal()
                if response == .alertThirdButtonReturn { return false }
                if response == .alertFirstButtonReturn { video.save(); if video.dirty { return false } }
            }
            video.close(); return true
        }
        guard let model = editorModels[id], model.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save your edits?"; alert.informativeText = "Save annotations to your local library before closing."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard Edits"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.save(); return !model.dirty
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let raw = window.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        DispatchQueue.main.async { self.editors[id] = nil; self.editorModels[id] = nil; self.videoModels[id] = nil; self.pins[id] = nil }
    }
    @objc func importImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, UTType(exportedAs: "local.sam.still.project", conformingTo: .json)]; panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls {
                importURL(url)
            }
        }
    }
    func importURL(_ url: URL) {
        if url.pathExtension.lowercased() == "stillshot" {
            do { let document = try ProjectDocument.read(url); if let source = document.sourceImage() { let item = try library.add(image: source, title: url.deletingPathExtension().lastPathComponent); try library.update(item, image: ImageRenderer.render(source, marks: document.marks), document: document); openItem(item) } }
            catch { showError("Couldn’t open project", error.localizedDescription) }; return
        }
        do { let item = try library.add(file: url, title: url.deletingPathExtension().lastPathComponent); openItem(item) }
        catch { showError("Couldn’t open image", error.localizedDescription) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL { importURL(url); continue }
            guard url.scheme?.lowercased() == "still", Preferences.shared.allowURLScheme else { continue }
            switch url.host?.lowercased() {
            case "capture-area": capture(.area)
            case "capture-window": capture(.window)
            case "capture-fullscreen": if confirmURLAction("capture your whole screen") { urlCapture = true; capture(.screen) }
            case "capture-text": capture(.text)
            case "capture-scrolling": showAllInOne(purpose: .scroll)
            case "all-in-one": showAllInOne()
            case "record": if confirmURLAction(recorder.recording ? "stop and save your screen recording" : "start recording your screen") { toggleRecording() }
            case "history": showHistory()
            case "restore": restoreLastCapture()
            case "settings": showMain()
            default: library.toast("Unknown Still URL action")
            }
        }
    }
    /// Another app or a web page can open still:// links. Actions that capture without you choosing an area
    /// (the whole screen, recording) ask first, so nothing is captured behind your back.
    private func confirmURLAction(_ action: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Allow a link to \(action)?"
        alert.informativeText = "Another app or a web page opened a still:// link. You can turn these links off in Settings → Advanced."
        alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Don’t Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func demo() { openEditor(image: DemoImage.make(), item: nil, isSample: true) }
    func pin(_ image: CGImage) {
        let id = UUID(), maxSize: CGFloat = 620
        let ratio = min(maxSize/CGFloat(image.width), maxSize/CGFloat(image.height), 1)
        let panel = PinnedPanel(contentRect: NSRect(x: 0, y: 0, width: CGFloat(image.width)*ratio, height: CGFloat(image.height)*ratio), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = "Pinned · Still"; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = Preferences.shared.pinShadow; panel.isMovableByWindowBackground = true
        panel.identifier = NSUserInterfaceItemIdentifier(id.uuidString); panel.delegate = self
        panel.contentView = NSHostingView(rootView: PinView(image: image, library: library, panel: panel))
        panel.center(); panel.orderFrontRegardless(); pins[id] = panel
    }
    func showPreview(_ item: CaptureItem) {
        dismissPreview(item.id); lastPreviewItem = item; overlaysHidden = false; library.loadThumbnail(item)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        let prefs = Preferences.shared, width = prefs.previewWidth
        let ratio = item.width > 0 && item.height > 0 ? Double(item.height)/Double(item.width) : 0.65
        let height = max(110, min(280, width*ratio)) + 34 // image plus the action bar
        let left = prefs.previewPosition.contains("Left"), top = prefs.previewPosition.contains("top")
        for id in previewOrder { if let old = previewPanels[id] { old.setFrameOrigin(CGPoint(x: old.frame.minX, y: old.frame.minY+(top ? -1 : 1)*(height+14))) } }
        let x = left ? screen.visibleFrame.minX+22 : screen.visibleFrame.maxX-width-22
        let y = top ? screen.visibleFrame.maxY-height-22 : screen.visibleFrame.minY+22
        let panel = QuickAccessPanel(contentRect: NSRect(x: x, y: y, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = QuickAccessHostingView(rootView: PreviewView(item: item, library: library, dismiss: { [weak self] in self?.dismissPreview(item.id) }))
        host.gesture = { [weak self] left in self?.performPreviewGesture(item, left: left) }
        panel.copyCapture = { [weak self] in self?.library.copy(item); self?.dismissPreview(item.id) }
        panel.openCapture = { [weak self] in self?.openItem(item); self?.dismissPreview(item.id) }
        panel.dismissCapture = { [weak self] in self?.dismissPreview(item.id) }
        panel.contentView = host
        NSApp.unhideWithoutActivation(); panel.orderFrontRegardless(); preview = panel; previewPanels[item.id] = panel; previewOrder.append(item.id)
        if previewOrder.count > 5, let oldest = previewOrder.first { dismissPreview(oldest) }
    }
    private func showRecordingHUD() {
        guard let screen = NSScreen.main else { return }
        // Resuming after a pause shows the HUD again; replace the earlier one rather than stacking another.
        recordingHUD?.close(); recordingHUD = nil
        let panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX-110, y: screen.visibleFrame.minY+24, width: 220, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingHUD(recorder: recorder))
        NSApp.unhideWithoutActivation(); panel.orderFrontRegardless(); recordingHUD = panel
    }
    private func captureTitle(_ type: String) -> String {
        "\(type) \(Date().formatted(date: .abbreviated, time: .standard))".replacingOccurrences(of: ":", with: ".")
    }
    func showError(_ title: String, _ text: String) {
        showMain(); let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.addButton(withTitle: "OK"); alert.runModal()
    }
    private func hideForCapture() {
        // Normal windows stay when Still's own windows may be captured; floating ones always step aside.
        for window in NSApp.windows where window.isVisible && !(Preferences.shared.captureOwnWindows && window.level == .normal) { window.orderOut(nil) }
    }
}

extension AppController {
    func applyAppearance() {
        let value = Preferences.shared.appearance
        NSApp.appearance = value == "system" ? nil : NSAppearance(named: value == "dark" ? .darkAqua : .aqua)
    }
    func setMenuBarVisible(_ visible: Bool) { statusItem?.isVisible = visible || recorder.recording }
    func reloadShortcuts() {
        hotkeys.register(); if !hotkeys.unavailable.isEmpty { library.toast("A shortcut is already in use. Choose a different combination.") }
        decorateMenu()
    }
    /// Gives the menu bar menu its icons and shows each capture's shortcut in the native right-hand column.
    private func decorateMenu() {
        let symbols = ["Capture Bar": "rectangle.dashed", "Capture Area": "viewfinder", "Capture Window": "macwindow", "Capture Full Screen": "display",
                       "Record / Stop Recording": "record.circle", "Capture Text": "text.viewfinder", "Open Image…": "photo", "Capture Previous Area": "arrow.counterclockwise",
                       "Scrolling Capture": "arrow.down.to.line.compact", "Capture History": "clock.arrow.circlepath", "Restore Last Capture": "arrow.uturn.backward",
                       "Hide / Show Overlays": "eye.slash", "Toggle Desktop Icons": "menubar.dock.rectangle", "Unlock Pinned Screenshots": "pin.slash", "Settings…": "gearshape", "Clipboard History": "doc.on.clipboard", "Check for Updates…": "arrow.down.circle", "Quit Still": "power"]
        let shortcuts = Shortcut.load()
        for item in menu.items where !item.isSeparatorItem {
            if let symbol = symbols[item.title] { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); Self.keepImageVisible(item) }
            let id = item.title == "Capture Bar" ? 5 : item.tag
            guard id > 0, let shortcut = shortcuts.first(where: { $0.id == UInt32(id) }), let code = shortcut.keyCode, let key = Shortcut.keyCharacters[code] else { item.keyEquivalent = ""; continue }
            item.keyEquivalent = key
            var flags: NSEvent.ModifierFlags = []
            if shortcut.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
            if shortcut.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            if shortcut.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
            if shortcut.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
            item.keyEquivalentModifierMask = flags
        }
    }
    /// macOS 27 hides menu item images unless the item asks to keep them. Set it by key so the
    /// app still builds with older SDKs that don't have `preferredImageVisibility`.
    static func keepImageVisible(_ item: NSMenuItem) {
        if item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) { item.setValue(1, forKey: "preferredImageVisibility") }
    }
    /// macOS keeps ⇧⌘4 for its own screenshot tool (symbolic hotkey 30) unless it is turned off in Keyboard settings.
    func checkSystemScreenshotShortcut() {
        guard let area = Shortcut.load().first(where: { $0.id == 1 }), area.keyCode == UInt32(kVK_ANSI_4), area.modifiers == UInt32(cmdKey|shiftKey) else { return }
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        let entry = hotkeys?["30"] as? [String: Any]
        let enabled = (entry?["enabled"] as? Bool) ?? ((entry?["enabled"] as? NSNumber)?.boolValue ?? true)
        guard enabled, !UserDefaults.standard.bool(forKey: "systemShortcutNoticeDismissed") else { return }
        let alert = NSAlert(); alert.messageText = "Turn off the macOS ⇧⌘4 shortcut"
        alert.informativeText = "macOS still uses ⇧⌘4 for its own screenshot tool, so Still can’t receive it yet.\n\nIn Keyboard Shortcuts → Screenshots, turn off “Save picture of selected area as a file”. Still will then open on ⇧⌘4, and Space switches to window capture."
        alert.addButton(withTitle: "Open Keyboard Shortcuts"); alert.addButton(withTitle: "Later"); alert.addButton(withTitle: "Don’t Ask Again")
        switch alert.runModal() {
        case .alertFirstButtonReturn: if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") { NSWorkspace.shared.open(url) }
        case .alertThirdButtonReturn: UserDefaults.standard.set(true, forKey: "systemShortcutNoticeDismissed")
        default: break
        }
    }
    @objc func toggleDesktop() { DesktopCover.shared.toggle() }
    @objc func toggleOverlays() {
        overlaysHidden.toggle()
        for panel in Array(previewPanels.values)+Array(pins.values) { if overlaysHidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() } }
    }
    /// The overlay takes keyboard focus; give it back so ⌘V lands in the app you were using.
    private func returnFocus() {
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        lastExternalApp?.activate()
    }
    private func restoreOverlays() { if !overlaysHidden { for panel in Array(previewPanels.values)+Array(pins.values) { panel.orderFrontRegardless() } } }
    @objc func showLastLinkQR() {
        if let link = library.lastLink ?? library.items.first(where: { $0.cloudURL != nil })?.cloudURL { QRCodePanel.show(link) }
        else { library.toast("Upload a capture first, then its link can be shown as a QR code") }
    }
    @objc func restoreLastCapture() { if let item = lastPreviewItem ?? library.items.first { showPreview(item) } }
    @objc func showHistory() {
        if let panel = historyPanel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = SelectionPanel(contentRect: CGRect(x: 0, y: 0, width: 880, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating; panel.isReleasedWhenClosed = false
        // The panel is borderless and History's colours are translucent, so it sits on the glass material.
        panel.contentView = Studio.glass(NSHostingView(rootView: HistoryView(library: library, dismiss: { [weak self] in self?.historyPanel?.close(); self?.historyPanel = nil })), in: panel, cornerRadius: 16)
        historyPanel = panel; panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showAllInOne(purpose: SelectionPurpose = .screenshot, delay: Int = 0) {
        guard !library.busy, !recorder.recording, !recorder.choosing, !recorder.stopping else { return }
        
        library.busy = true
        let previous = NSWorkspace.shared.frontmostApplication
        if previous?.bundleIdentifier != Bundle.main.bundleIdentifier { lastExternalApp = previous }
        // Don't activate anything before the screen is grabbed: that would close open menus and Spotlight.
        DesktopCover.shared.beginCapture()
        Task {
            guard await CaptureCountdown.run(seconds: delay) else { library.busy = false; DesktopCover.shared.endCapture(); return }
            selection.begin(purpose)
        }
    }
    @objc func capturePrevious() {
        guard !recorder.recording, !recorder.stopping, !recorder.choosing else { library.toast("Finish the current recording first"); return }
        guard !library.busy, let saved = UserDefaults.standard.dictionary(forKey: "lastSelection") as? [String: Double],
              let screen = NSScreen.screens.first(where: { (selfScreenID($0)) == saved["screen"] }),
              let x = saved["x"], let y = saved["y"], let w = saved["w"], let h = saved["h"] else { showAllInOne(); return }
        
        library.busy = true; hideForCapture(); DesktopCover.shared.beginCapture()
        Task {
            defer { library.busy = false; DesktopCover.shared.endCapture(); restoreOverlays() }
            do { try await Task.sleep(nanoseconds: 180_000_000); await completeScreenshot(try await ScreenCaptureAPI.image(screen: screen, rect: CGRect(x: x, y: y, width: w, height: h))) }
            catch { showError("Capture failed", error.localizedDescription) }
        }
    }
    private func selfScreenID(_ screen: NSScreen) -> Double { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.doubleValue ?? 0 }
    /// Encoding a screen-sized PNG takes 100 to 300 ms, so it happens here off the main thread, before the capture is
    /// stored and shown. Callers wait for this to finish, so the clipboard is ready before focus goes back.
    private func completeScreenshot(_ image: CGImage, text: Bool = false) async {
        library.permissionGranted = true; library.permissionError = nil
        do {
            let copying = library.autoCopy && !text
            let encoded = try await Task.detached(priority: .userInitiated) { () -> (png: Data, clipboard: Data?, thumbnail: CGImage?) in
                async let png = ImageRenderer.libraryData(image)
                async let clipboard = copying ? ImageRenderer.data(image) : nil
                return (try await png, try await clipboard, ImageRenderer.thumbnail(image, maxPixelSize: 560))
            }.value
            let item = try library.add(png: encoded.png, width: image.width, height: image.height, title: library.captureName(width: image.width, height: image.height))
            if let thumbnail = encoded.thumbnail { library.storeThumbnail(item.id, image: thumbnail) }
            if library.captureSound { NSSound(named: "Tink")?.play() }
            if text {
                Task {
                    do {
                        let output = try await recognizeText(in: image)
                        if output.isEmpty { showError("No text found", "Select a larger or clearer area and try again.") }
                        else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string); library.updateText(item, text: output); showCopyToast("Text copied to clipboard") }
                    } catch { showError("Text recognition failed", error.localizedDescription) }
                }
                return
            }
            if let clipboard = encoded.clipboard { library.copy(png: clipboard) }
            if Preferences.shared.saveAfterCapture { library.quickSave(item) }
            if Preferences.shared.pinAfterCapture { pin(image) }
            if library.showPreview { showPreview(item) }
            if Preferences.shared.annotateAfterCapture { openItem(item) }
            // Captures started by a still:// link are never uploaded automatically.
            if Preferences.shared.autoUploadImages && !urlCapture { upload(item) }
            urlCapture = false
        } catch { showError("Couldn’t save capture", error.localizedDescription) }
    }
    func showCopyToast(_ text: String) {
        guard let screen = NSScreen.main else { return }
        let panel = NSPanel(contentRect: CGRect(x: screen.visibleFrame.midX-150, y: screen.visibleFrame.minY+60, width: 300, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: Label(text, systemImage: "checkmark.circle.fill").font(.system(size: 13)).padding(13).background(.ultraThickMaterial, in: Capsule()))
        panel.orderFrontRegardless(); DispatchQueue.main.asyncAfter(deadline: .now()+2.5) { panel.close() }
    }
    private func startAreaRecording(screen: NSScreen, rect: CGRect) {
        recorder.systemAudio = library.systemAudio; recorder.microphone = library.microphoneAudio
        recorder.recordArea(screen: screen, rect: rect)
    }
    func openVideoEditor(_ item: CaptureItem) {
        let id = item.id
        if let window = editors[id] { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = item.title; window.minSize = NSSize(width: 950, height: 640); window.isReleasedWhenClosed = false; window.delegate = self; window.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        let model = VideoEditorModel(item: item, library: library); videoModels[id] = model
        window.contentView = Studio.glass(NSHostingView(rootView: VideoEditorView(model: model).tint(Studio.accent)), in: window); editors[id] = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func performPreviewGesture(_ item: CaptureItem, left: Bool) {
        switch left ? Preferences.shared.previewSwipeLeft : Preferences.shared.previewSwipeRight {
        case "copy": library.copy(item); dismissPreview(item.id)
        case "save": library.quickSave(item); dismissPreview(item.id)
        case "edit": openItem(item); dismissPreview(item.id)
        case "upload": upload(item)
        default: dismissPreview(item.id)
        }
    }
    func dismissPreview(_ id: UUID) { previewPanels[id]?.close(); previewPanels[id] = nil; previewOrder.removeAll { $0 == id } }
}

extension AppController {
    @objc func unlockPins() { for panel in pins.values { panel.ignoresMouseEvents = false; panel.orderFrontRegardless() } }
    func shareItem(_ item: CaptureItem) {
        let picker = NSSharingServicePicker(items: [library.url(item)])
        if let panel = previewPanels[item.id], let view = panel.contentView { picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX) }
        else if let view = NSApp.keyWindow?.contentView { picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY) }
    }
}

extension AppController {
    private func showRecordingSetup(screen: NSScreen? = nil, rect: CGRect? = nil, windowID: CGWindowID? = nil) {
        recordingSetupPanel?.close(); recordingBorder?.close()
        guard let target = screen ?? NSScreen.main else { return }
        let panel = SelectionPanel(contentRect: CGRect(x: target.visibleFrame.midX-180, y: target.visibleFrame.midY-160, width: 360, height: 330), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating; panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: RecordingSetupView(library: library, selectedSize: rect?.size, selectedWindow: windowID != nil, chooseArea: { [weak self] in self?.closeRecordingSetup(); self?.showAllInOne(purpose: .recording) }, cancel: { [weak self] in self?.closeRecordingSetup(); self?.restoreOverlays() }, record: { [weak self] format, studio, full, size in
            guard let self else { return }; self.closeRecordingSetup(); self.forceVideoEditor = studio
            Preferences.shared.recordingFormat = format; self.recorder.systemAudio = self.library.systemAudio; self.recorder.microphone = self.library.microphoneAudio
            DesktopCover.shared.beginCapture(); self.lastExternalApp?.activate()
            if full { self.recorder.recordArea(screen: target, rect: CGRect(origin: .zero, size: target.frame.size)) }
            else if let windowID { self.recorder.recordWindow(id: windowID) }
            else if let screen, let rect { let updated = CGRect(origin: rect.origin, size: size).intersection(CGRect(origin: .zero, size: screen.frame.size)); self.startAreaRecording(screen: screen, rect: updated) }
            // No area chosen: record the whole display the setup panel is on. (The system picker
            // doesn't reliably appear for menu bar apps, which left recording stuck.)
            else { self.recorder.recordArea(screen: target, rect: CGRect(origin: .zero, size: target.frame.size)) }
        }))
        recordingSetupPanel = panel
        if let rect {
            let frame = CGRect(x: target.frame.minX+rect.minX, y: target.frame.maxY-rect.maxY, width: rect.width, height: rect.height)
            let border = NSPanel(contentRect: frame.insetBy(dx: -1, dy: -1), styleMask: .borderless, backing: .buffered, defer: false)
            border.level = .floating; border.isOpaque = false; border.backgroundColor = .clear; border.ignoresMouseEvents = true; border.hidesOnDeactivate = false
            border.contentView = NSHostingView(rootView: Rectangle().stroke(Color.accentColor, lineWidth: 2)); recordingBorder = border; border.orderFrontRegardless()
        }
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func closeRecordingSetup() { recordingSetupPanel?.close(); recordingSetupPanel = nil; recordingBorder?.close(); recordingBorder = nil }
}

extension AppController: NSMenuDelegate {
    /// The Clipboard History submenu is rebuilt each time it opens, so it's always current.
    func menuNeedsUpdate(_ menu: NSMenu) { if menu === clipboardMenu { fillClipboardMenu(menu, numbered: false) } }
    /// Carbon holds hotkeys back until an open menu closes. While the menu bar menu is open, the shortcuts with a row in
    /// it stay out of the way, so the menu's own key equivalents close it and run the capture right away.
    func menuWillOpen(_ menu: NSMenu) { if menu === self.menu { hotkeys.suspend([1, 2, 3, 4, 5, 8]) } }
    func menuDidClose(_ menu: NSMenu) { if menu === self.menu { hotkeys.register() } }
}
