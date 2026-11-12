import AppKit
import SwiftUI
import ScreenCaptureKit
import StillCore

enum SelectionPurpose { case screenshot, text, scroll, recording }
@MainActor enum ScreenCaptureAPI {
    static func filter(screen: NSScreen) async throws -> SCContentFilter {
        try filter(screen: screen, content: await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
    }
    static func filter(screen: NSScreen, content: SCShareableContent) throws -> SCContentFilter {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw NSError(domain: "Still", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected display is no longer connected."]) }
        let pid = ProcessInfo.processInfo.processIdentifier
        if Preferences.shared.captureOwnWindows {
            // Keep Still's normal windows (Settings, editor, History) in the shot; leave out its floating
            // previews, pins, recording controls and the capture overlay. Desktop covers, Still's open menus
            // and its menu bar icon stay visible.
            let floating = content.windows.filter { $0.owningApplication?.processID == pid && ![0, 25, 101].contains($0.windowLayer) && !DesktopCover.shared.windowIDs.contains($0.windowID) }
            return SCContentFilter(display: display, excludingWindows: floating)
        }
        let own = content.applications.filter { $0.processID == pid }
        let covers = content.windows.filter { DesktopCover.shared.windowIDs.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: covers)
    }
    static func image(screen: NSScreen, rect: CGRect? = nil, filter: SCContentFilter? = nil) async throws -> CGImage {
        let selected: SCContentFilter
        if let filter { selected = filter } else { selected = try await Self.filter(screen: screen) }
        let config = SCStreamConfiguration()
        let region = rect ?? CGRect(origin: .zero, size: screen.frame.size)
        config.sourceRect = region
        config.width = max(1, Int(region.width*screen.backingScaleFactor))
        config.height = max(1, Int(region.height*screen.backingScaleFactor))
        config.showsCursor = Preferences.shared.includeCursor
        return try await SCScreenshotManager.captureImage(contentFilter: selected, configuration: config)
    }
    /// Every display at once, from one window list: fetching the list costs as much as the grab itself, and
    /// grabbing together keeps the frozen images from the same moment.
    static func images(screens: [NSScreen]) async -> [ObjectIdentifier: Result<CGImage, Error>] {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { return Dictionary(uniqueKeysWithValues: screens.map { (ObjectIdentifier($0), .failure(error)) }) }
        let grabs = screens.map { screen in (ObjectIdentifier(screen), Task { try await image(screen: screen, filter: try filter(screen: screen, content: content)) }) }
        var results: [ObjectIdentifier: Result<CGImage, Error>] = [:]
        for (id, grab) in grabs { results[id] = await grab.result }
        return results
    }
}

@MainActor final class CaptureSelection: ObservableObject {
    @Published var width = ""
    @Published var height = ""
    @Published var aspect = 0.0
    @Published var purpose = SelectionPurpose.screenshot { didSet { if pickingScreen { pickingScreen = false; views.forEach { $0.windowModeChanged() } } } }
    /// Space toggles between dragging an area and clicking a window, like the system screenshot overlay.
    @Published var windowMode = false
    /// With more than one display, the bar's Screen button asks which: each display lights up under the pointer and
    /// a click takes it. (The bar is on one display, so "the display under the pointer" would always be that one.)
    @Published private(set) var pickingScreen = false
    /// The display the bar is on; it moves to whichever display the pointer goes to.
    private var barScreen: NSScreen?
    private(set) var windows: [OverlayWindow] = []
    private var panels: [NSPanel] = []
    private var bar: NSPanel?
    private var images: [ObjectIdentifier: CGImage] = [:]
    private var views: [SelectionSurface] = []
    private var active = false
    private var keyboardMonitor: Any?
    private var captureTask: Task<Void, Never>?
    private var holdingSpace = false
    var allowsWindowSelection: Bool { purpose == .screenshot || purpose == .recording }
    var onWindowSelected: ((CGWindowID, NSScreen, CGRect) -> Void)?
    var onSelected: ((CGImage, NSScreen, CGRect, SelectionPurpose) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?
    func begin(_ purpose: SelectionPurpose) {
        guard !active else { return }
        self.purpose = purpose; active = true; windowMode = false
        installKeyboardMonitor()
        // Grab every display first, before Still takes focus, so open menus, Spotlight and hover states
        // are in the picture. The overlay then sits on that frozen image, like the system tool.
        captureTask = Task {
            var shots: [ObjectIdentifier: CGImage] = [:]
            var failures: [String] = []
            // The screen grab waits on the system, so the window list (for window mode) is read meanwhile.
            async let grabbing = ScreenCaptureAPI.images(screens: NSScreen.screens)
            windows = OverlayWindow.onScreen()
            let grabs = await grabbing
            for screen in NSScreen.screens {
                guard !Task.isCancelled else { return }
                do { shots[ObjectIdentifier(screen)] = try grabs[ObjectIdentifier(screen)]?.get() }
                catch { let error = error as NSError; failures.append("\(screen.localizedName): \(error.localizedDescription) (\(error.domain) \(error.code))") }
            }
            guard active, !Task.isCancelled else { return }
            guard !shots.isEmpty else {
                close()
                onError?(NSError(domain: "Still", code: 2, userInfo: [NSLocalizedDescriptionKey: "Capture could not start. " + (failures.isEmpty ? "No connected displays were found." : failures.joined(separator: "\n"))]))
                return
            }
            images = shots
            // Still's own menu was in the grab; close it now so the overlay can take the pointer.
            AppController.shared.closeMenus()
            for screen in NSScreen.screens {
                let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "Capture Selection"
                panel.level = .screenSaver; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.acceptsMouseMovedEvents = true
                // A clear window lets clicks fall through; the overlay must catch every one.
                panel.ignoresMouseEvents = false
                // Stay up if you switch apps mid-selection; otherwise Still would stay "busy" with no overlay.
                panel.hidesOnDeactivate = false
                let view = SelectionSurface(screen: screen, coordinator: self)
                view.frame = CGRect(origin: .zero, size: screen.frame.size)
                if let shot = shots[ObjectIdentifier(screen)] { view.setSnapshot(shot) }
                panel.contentView = view; panels.append(panel); views.append(view)
                // Keystrokes (Space, Esc, Enter, arrows) go to the selection view, not the bare window.
                panel.initialFirstResponder = view; panel.makeFirstResponder(view)
                panel.orderFrontRegardless()
            }
            showBar()
            NSApp.activate(ignoringOtherApps: true)
            if let key = panels.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? panels.first { key.makeKeyAndOrderFront(nil); key.makeFirstResponder(key.contentView) }
        }
    }
    /// Builds the overlay's views once, unseen, so the first capture after launch doesn't pay for loading them.
    func prewarm() {
        guard !active, let screen = NSScreen.main else { return }
        _ = barPanel()
        let panel = SelectionPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = SelectionSurface(screen: screen, coordinator: self); panel.contentView?.layoutSubtreeIfNeeded()
    }
    /// Still's capture bar: a slim pill along the bottom of the screen the pointer is on.
    private func showBar() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let panel = barPanel()
        place(panel, on: screen)
        panel.orderFrontRegardless(); bar = panel
    }
    private func place(_ panel: NSPanel, on screen: NSScreen) {
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        panel.setFrame(CGRect(x: screen.frame.midX-size.width/2, y: screen.visibleFrame.minY+28, width: size.width, height: size.height), display: true)
        barScreen = screen
    }
    /// The pointer went onto another display: the bar goes with it, so its buttons are always on the display you're
    /// working on (a laptop's own screen included, when Still was opened from another display's menu bar).
    func clearAdjusting(except view: SelectionSurface) { for other in views where other !== view { other.clearAdjusting() } }
    func pointerEntered(_ screen: NSScreen) {
        guard active, let bar, barScreen !== screen else { return }
        place(bar, on: screen)
    }
    /// The bar is built once and kept, hidden, between captures: laying out its SwiftUI view is a noticeable part of
    /// the wait otherwise. It shows this coordinator's state, so nothing carries over from the last capture.
    private var keptBar: NSPanel?
    private func barPanel() -> NSPanel {
        if let keptBar { return keptBar }
        let host = FirstClickHostingView(rootView: CaptureBar(selection: self))
        let size = host.fittingSize
        let panel = SelectionPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Capture Bar"; panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue+1); panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = host; panel.hidesOnDeactivate = false
        keptBar = panel
        return panel
    }
    func setDimensions() {
        guard let width = Double(width), let height = Double(height), width > 1, height > 1 else { return }
        for view in views { view.fixedSize = CGSize(width: min(width, view.bounds.width), height: min(height, view.bounds.height)); view.refresh() }
    }
    func finish(on screen: NSScreen, rect: CGRect) {
        guard active else { return }
        let purpose = self.purpose, source = images[ObjectIdentifier(screen)]
        if Preferences.shared.rememberSelection {
            UserDefaults.standard.set(["screen": (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.doubleValue ?? 0, "x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height], forKey: "lastSelection")
        }
        close()
        Task {
            do {
                let image: CGImage
                if let source {
                    let scaleX = CGFloat(source.width)/screen.frame.width, scaleY = CGFloat(source.height)/screen.frame.height
                    image = try ImageRenderer.crop(source, to: CGRect(x: rect.minX*scaleX, y: rect.minY*scaleY, width: rect.width*scaleX, height: rect.height*scaleY))
                } else {
                    image = try await ScreenCaptureAPI.image(screen: screen, rect: rect)
                }
                onSelected?(image, screen, rect, purpose)
            } catch { onError?(error) }
        }
    }
    /// F: the whole display under the pointer.
    func fullscreen() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        finish(on: screen, rect: CGRect(origin: .zero, size: screen.frame.size))
    }
    /// The bar's Screen button: straight away with one display, otherwise click the display you want.
    func chooseScreen() {
        guard NSScreen.screens.count > 1 else { fullscreen(); return }
        if windowMode { windowMode = false }
        pickingScreen.toggle(); views.forEach { $0.windowModeChanged() }
    }
    func window() { close(); onCancel?(); DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { AppController.shared.capture(.window) } }
    func toggleWindowMode() { setWindowMode(!windowMode) }
    func setWindowMode(_ on: Bool) {
        if pickingScreen { pickingScreen = false; if on == windowMode { views.forEach { $0.windowModeChanged() } } }
        guard allowsWindowSelection || !on, on != windowMode else { return }; windowMode = on; views.forEach { $0.windowModeChanged() }
    }
    func capture(window: OverlayWindow) {
        if purpose == .recording {
            guard let primary = NSScreen.screens.first,
                  let screen = NSScreen.screens.first(where: { CGRect(x: $0.frame.minX, y: primary.frame.maxY-$0.frame.maxY, width: $0.frame.width, height: $0.frame.height).intersects(window.frame) }) else { return }
            let local = CGRect(x: window.frame.minX-screen.frame.minX, y: window.frame.minY-(primary.frame.maxY-screen.frame.maxY), width: window.frame.width, height: window.frame.height)
            close(); onWindowSelected?(window.id, screen, local); return
        }
        if window.popup, let primary = NSScreen.screens.first,
           let screen = NSScreen.screens.first(where: { CGRect(x: $0.frame.minX, y: primary.frame.maxY-$0.frame.maxY, width: $0.frame.width, height: $0.frame.height).intersects(window.frame) }) {
            let local = CGRect(x: window.frame.minX-screen.frame.minX, y: window.frame.minY-(primary.frame.maxY-screen.frame.maxY), width: window.frame.width, height: window.frame.height)
            finish(on: screen, rect: local.intersection(CGRect(origin: .zero, size: screen.frame.size))); return
        }
        close(); onCancel?(); DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { AppController.shared.capture(.window, windowID: window.id) } }
    /// Starts again after a five-second countdown, keeping what was being captured (a screenshot, text or a recording).
    func timer() { let purpose = purpose; close(); onCancel?(); DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { AppController.shared.showAllInOne(purpose: purpose, delay: 5) } }
    func cancel() { close(); onCancel?() }
    private func installKeyboardMonitor() {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.active else { return event }
            let editing = event.window?.firstResponder is NSTextView
            switch CaptureKeyboardPolicy.action(keyCode: event.keyCode, keyUp: event.type == .keyUp, editingText: editing, windowSelectionAllowed: self.allowsWindowSelection, hasCommandModifier: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty) {
            case .cancel: self.cancel(); return nil
            case .beginWindowSelection:
                // Mid-drag, Space moves the selection instead (like the system tool); otherwise it picks a window.
                if let dragging = self.views.first(where: { $0.isSelecting }) { dragging.setMoving(true); return nil }
                if !event.isARepeat, !self.windowMode { self.holdingSpace = true; self.setWindowMode(true) }
                return nil
            case .endWindowSelection:
                self.views.forEach { $0.setMoving(false) }
                if self.holdingSpace { self.holdingSpace = false; self.setWindowMode(false); return nil }
                return event
            case .passThrough: return event
            }
        }
    }
    func close() {
        captureTask?.cancel(); captureTask = nil
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor); self.keyboardMonitor = nil }
        holdingSpace = false; pickingScreen = false; barScreen = nil
        active = false; for panel in panels { panel.close() }; panels = []; views = []; images = [:]; bar?.orderOut(nil); bar = nil }
}
/// A normal-layer window from the Window Server list, front to back, in global top-left coordinates.
struct OverlayWindow {
    let id: CGWindowID
    let frame: CGRect
    /// The app the window belongs to, for finding the parts inside it (see WindowPartsFinder).
    var pid: pid_t = 0
    /// Menus, Spotlight and other pop-ups close once Still takes focus, so they're cut from the frozen image.
    var popup = false
    @MainActor static func onScreen() -> [OverlayWindow] {
        let own = ProcessInfo.processInfo.processIdentifier
        let pickPopups = Preferences.shared.pickPopups, captureOwn = Preferences.shared.captureOwnWindows
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            let layer = info[kCGWindowLayer as String] as? Int ?? 0, owner = info[kCGWindowOwnerPID as String] as? pid_t
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            // Normal windows always; menus, Spotlight and other pop-ups when allowed (not the Dock, menu bar or
            // screen-wide system layers); Still's own normal windows when allowed, never its overlays.
            let popup = pickPopups && layer > 0 && layer < 1000 && ![20, 24, 25].contains(layer) && !["Dock", "Window Server"].contains(ownerName)
            guard layer == 0 || popup, owner != own || (captureOwn && (layer == 0 || layer == 101)),
                  let id = info[kCGWindowNumber as String] as? CGWindowID, let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 40, frame.height > 40,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0 else { return nil }
            return OverlayWindow(id: id, frame: frame, pid: owner ?? 0, popup: layer > 0)
        }
    }
}
final class FirstClickHostingView<Content: View>: NSHostingView<Content> { override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } }
final class SelectionPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }

/// The selection overlay. Everything is a Core Animation layer that only moves on pointer events,
/// so tracking stays on the GPU instead of redrawing a full-screen image every frame.
@MainActor final class SelectionSurface: NSView {
    let display: NSScreen
    unowned let coordinator: CaptureSelection
    var fixedSize: CGSize?
    private var snapshot: CGImage?
    private var anchor: CGPoint?
    var isSelecting: Bool { anchor != nil }
    private var pointer = CGPoint(x: -100, y: -100)
    /// The magnifier's zoom (points per screen pixel). The scroll wheel steps through SelectionGeometry's steps, the box
    /// grows with it, and the choice is remembered for the next capture.
    private var magnifierZoom: Double = {
        let saved = UserDefaults.standard.double(forKey: "magnifierZoom")
        return SelectionGeometry.magnifierZooms.contains(saved) ? saved : 8
    }()
    private var region = CGRect.zero
    private var hovered: OverlayWindow?
    /// How far the wheel has gone into the hovered window's parts (0 = the whole window), and the parts found per
    /// window, in this view's coordinates.
    private var partDepth = 0, lastPartStep: TimeInterval = 0
    private var windowParts: [CGWindowID: [CGRect]] = [:]
    private var spaceHeld = false
    private let root = CALayer()
    private let frozen = CALayer()
    private let shade = CAShapeLayer()
    private let border = CAShapeLayer()
    private let crossH = CALayer(), crossV = CALayer()
    private let label = CATextLayer()
    private let labelBack = CALayer()
    private let magnifier = CALayer()
    private let highlight = CALayer()
    // The colour under the crosshair, under the magnifier; C copies it.
    private let colourBack = CALayer(), colourSwatch = CALayer()
    private let colourLabel = CATextLayer()
    // The zoom, in the magnifier's corner, so a turn of the wheel has visible feedback.
    private let zoomBack = CALayer(), zoomLabel = CATextLayer()
    private var copiedColour: String?
    /// Adjusting the area before it's captured, as the Mac's own tool does: once the drag is let go the box stays, a hand
    /// inside it moves it, its edges and corners resize it, and Capture (or Return, or a double-click inside) takes it.
    /// Settings → Screenshots can turn this off, for a capture the moment the mouse is let go.
    private var adjusting = false
    private var grab: (handle: String, from: CGPoint, start: CGRect)?
    private let captureBack = CALayer(), captureLabel = CATextLayer()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // Still isn't the active app while selecting (so menus and Spotlight stay open); take the first click anyway.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(screen: NSScreen, coordinator: CaptureSelection) {
        self.display = screen; self.coordinator = coordinator
        super.init(frame: .zero)
        layer = root; wantsLayer = true
        root.isGeometryFlipped = true
        let scale = screen.backingScaleFactor
        frozen.contentsGravity = .resize; frozen.isHidden = true
        shade.fillRule = .evenOdd; shade.fillColor = NSColor.black.withAlphaComponent(0.28).cgColor
        border.fillColor = nil; border.strokeColor = NSColor.white.withAlphaComponent(0.92).cgColor; border.lineWidth = 1
        for line in [crossH, crossV] { line.backgroundColor = NSColor.white.withAlphaComponent(0.75).cgColor }
        labelBack.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor; labelBack.cornerRadius = 5
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium); label.fontSize = 12
        label.foregroundColor = NSColor.white.cgColor; label.contentsScale = scale; label.alignmentMode = .center
        magnifier.cornerRadius = 9; magnifier.masksToBounds = true; magnifier.borderColor = NSColor.white.cgColor; magnifier.borderWidth = 1.5
        magnifier.magnificationFilter = .nearest; magnifier.isHidden = true
        highlight.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.3).cgColor
        highlight.borderColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor; highlight.borderWidth = 1; highlight.isHidden = true
        colourBack.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor; colourBack.cornerRadius = 5
        colourSwatch.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor; colourSwatch.borderWidth = 1
        colourLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium); colourLabel.fontSize = 10
        colourLabel.foregroundColor = NSColor.white.cgColor; colourLabel.contentsScale = scale
        zoomBack.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor; zoomBack.cornerRadius = 4
        zoomLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium); zoomLabel.fontSize = 10
        zoomLabel.foregroundColor = NSColor.white.cgColor; zoomLabel.contentsScale = scale; zoomLabel.alignmentMode = .center
        for layer in [frozen, shade, highlight, border, crossH, crossV, magnifier, zoomBack, zoomLabel, colourBack, colourSwatch, colourLabel, labelBack, label, captureBack, captureLabel] as [CALayer] { layer.actions = Self.noAnimations; root.addSublayer(layer) }
        captureBack.backgroundColor = NSColor(hex: "6E6E73").cgColor; captureBack.cornerRadius = 16; captureBack.isHidden = true
        captureBack.shadowOpacity = 0.4; captureBack.shadowRadius = 10; captureBack.shadowOffset = CGSize(width: 0, height: 4)
        captureLabel.string = "Capture  ↩"; captureLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold); captureLabel.fontSize = 13
        captureLabel.foregroundColor = NSColor.white.cgColor; captureLabel.contentsScale = scale; captureLabel.alignmentMode = .center; captureLabel.isHidden = true
        if Preferences.shared.rememberSelection, let saved = UserDefaults.standard.dictionary(forKey: "lastSelection"), let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.doubleValue, (saved["screen"] as? Double) == id, let x = saved["x"] as? Double, let y = saved["y"] as? Double, let w = saved["w"] as? Double, let h = saved["h"] as? Double {
            region = CGRect(x: x, y: y, width: w, height: h).intersection(CGRect(origin: .zero, size: screen.frame.size))
            coordinator.width = String(Int(region.width)); coordinator.height = String(Int(region.height))
        }
        if let location = window?.mouseLocationOutsideOfEventStream { pointer = convert(location, from: nil) }
        else { let p = NSEvent.mouseLocation; pointer = CGPoint(x: p.x-screen.frame.minX, y: screen.frame.maxY-p.y) }
    }
    required init?(coder: NSCoder) { fatalError() }
    private static let noAnimations: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "hidden": NSNull(), "frame": NSNull(), "string": NSNull(), "contentsRect": NSNull(), "opacity": NSNull()]

    override func layout() { super.layout(); root.frame = bounds; frozen.frame = bounds; refresh() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: moving ? .closedHand : coordinator.pickingScreen ? .pointingHand : coordinator.windowMode ? Self.cameraCursor : .crosshair) }
    private static let cameraCursor: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular).applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return .pointingHand }
        let image = NSImage(size: CGSize(width: 28, height: 24), flipped: false) { rect in
            let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.8); shadow.shadowBlurRadius = 2; shadow.set()
            symbol.draw(in: CGRect(x: (rect.width-symbol.size.width)/2, y: (rect.height-symbol.size.height)/2, width: symbol.size.width, height: symbol.size.height))
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 14, y: 12))
    }()

    func setSnapshot(_ image: CGImage) {
        snapshot = image
        CATransaction.begin(); CATransaction.setDisableActions(true)
        magnifier.contents = image
        frozen.contents = image; frozen.isHidden = false
        CATransaction.commit()
        refresh()
    }

    /// Global top-left window frame → this screen's flipped view coordinates.
    private func local(_ frame: CGRect) -> CGRect {
        let primary = NSScreen.screens.first?.frame.height ?? display.frame.height
        return frame.offsetBy(dx: -display.frame.minX, dy: -(primary-display.frame.maxY))
    }
    private func updateHover() {
        let next = coordinator.windowMode ? coordinator.windows.first(where: { local($0.frame).contains(pointer) }) : nil
        if next?.id != hovered?.id { partDepth = 0 }
        hovered = next
    }
    /// The hovered window's parts: from macOS's accessibility tree when Still may read it, otherwise from the frozen
    /// picture. Found once per window, when first needed.
    private func parts(of window: OverlayWindow) -> [CGRect] {
        if let known = windowParts[window.id] { return known }
        let frame = local(window.frame)
        var found = WindowPartsFinder.accessibility(pid: window.pid, frame: window.frame).map { local($0) }
        if found.isEmpty, let snapshot { found = WindowPartsFinder.picture(snapshot, region: frame.intersection(bounds), viewSize: bounds.size) }
        let useful = WindowParts.useful(found, in: frame)
        windowParts[window.id] = useful
        return useful
    }
    private func selectedPart() -> (rect: CGRect, depth: Int, deepest: Int)? {
        guard let hovered else { return nil }
        return WindowParts.part(of: local(hovered.frame), parts: parts(of: hovered), at: pointer, depth: partDepth)
    }
    func windowModeChanged() { anchor = nil; partDepth = 0; if coordinator.windowMode || coordinator.pickingScreen { adjusting = false; grab = nil }; updateHover(); window?.invalidateCursorRects(for: self); refresh() }

    func refresh() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let picking = coordinator.pickingScreen
        // Picking a display draws like window mode: no crosshair or magnifier, a highlight and a hint.
        let windowMode = coordinator.windowMode || picking
        let onScreen = bounds.contains(pointer)
        // Area mode: dim only outside the selection, like the system tool; window mode: blue highlight.
        let hasRegion = !windowMode && region.width > 0
        shade.isHidden = !hasRegion
        if hasRegion { let path = CGMutablePath(); path.addRect(bounds); path.addRect(region); shade.path = path; border.path = CGPath(rect: region.insetBy(dx: 0.5, dy: 0.5), transform: nil) }
        border.isHidden = !hasRegion
        let part = windowMode && !picking ? selectedPart() : nil
        if picking { highlight.frame = bounds.insetBy(dx: 2, dy: 2); highlight.isHidden = !onScreen }
        else if let part { highlight.frame = part.rect.intersection(bounds); highlight.isHidden = false } else { highlight.isHidden = true }
        let crosshair = Preferences.shared.crosshair
        let showCross = !windowMode && onScreen && crosshair != "disabled" && !adjusting
        crossH.isHidden = !showCross; crossV.isHidden = !showCross
        if showCross {
            let px = 1/display.backingScaleFactor
            if crosshair == "full" { crossH.frame = CGRect(x: 0, y: pointer.y, width: bounds.width, height: px); crossV.frame = CGRect(x: pointer.x, y: 0, width: px, height: bounds.height) }
            else { crossH.frame = CGRect(x: pointer.x-20, y: pointer.y, width: 40, height: px); crossV.frame = CGRect(x: pointer.x, y: pointer.y-20, width: px, height: 40) }
        }
        // The magnifier grows with its zoom and sits on whichever side of the pointer has room, never under it.
        let showMagnifier = Preferences.shared.magnifier && !windowMode && anchor == nil && !adjusting && onScreen && snapshot != nil
        magnifier.isHidden = !showMagnifier; zoomBack.isHidden = !showMagnifier; zoomLabel.isHidden = !showMagnifier
        if showMagnifier, let snapshot {
            let w = CGFloat(snapshot.width), h = CGFloat(snapshot.height), sx = w/bounds.width, sy = h/bounds.height
            let size = SelectionGeometry.magnifierSize(zoom: magnifierZoom), patch = size/magnifierZoom
            magnifier.contentsRect = CGRect(x: (pointer.x*sx-patch/2)/w, y: (pointer.y*sy-patch/2)/h, width: patch/w, height: patch/h)
            magnifier.frame = SelectionGeometry.magnifierFrame(pointer: pointer, size: size, within: bounds)
            let tag = "\(Int(magnifierZoom))×", tagWidth = (tag as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)]).width
            zoomBack.frame = CGRect(x: magnifier.frame.maxX-tagWidth-12, y: magnifier.frame.maxY-18, width: tagWidth+8, height: 14)
            zoomLabel.string = tag; zoomLabel.frame = CGRect(x: zoomBack.frame.minX, y: zoomBack.frame.minY+1, width: zoomBack.frame.width, height: 13)
        }
        let text: String
        if picking { text = "Click to \(coordinator.purpose == .recording ? "record" : "capture") \(display.localizedName)" }
        else if windowMode {
            let verb = coordinator.purpose == .recording ? "record" : "capture"
            if hovered == nil { text = "Hold Space and move over a window" }
            else if let part, part.depth > 0 { text = "Click to \(verb) this part · scroll \(part.depth < part.deepest ? "for a smaller part, or " : "")up for the whole window" }
            else if let part, part.deepest > 0 { text = "Click to \(verb) window · scroll down for the page inside" }
            else { text = "Click to \(verb) window" }
        }
        else if region.width > 0 { text = "\(Int(region.width)) × \(Int(region.height))" + (adjusting ? "  ·  drag to move or resize  ·  Return to capture" : anchor != nil && !moving ? "  ·  hold Space to move" : "") }
        else { text = "" }
        label.isHidden = text.isEmpty || !onScreen; labelBack.isHidden = label.isHidden
        if !label.isHidden {
            label.string = text
            let size = (text as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)])
            var origin = CGPoint(x: min(bounds.width-size.width-18, max(10, pointer.x+16)), y: min(bounds.height-30, max(10, pointer.y+16)))
            // Kept clear of the magnifier and its colour chip: above the pointer instead, if it would cover them.
            let lens = magnifier.frame.insetBy(dx: 0, dy: -2).union(magnifier.frame.offsetBy(dx: 0, dy: 26))
            if showMagnifier, lens.intersects(CGRect(x: origin.x-6, y: origin.y-3, width: size.width+12, height: size.height+6)) { origin.y = max(10, pointer.y-size.height-24) }
            if adjusting, !captureBack.isHidden, captureBack.frame.insetBy(dx: -8, dy: -8).intersects(CGRect(x: origin.x-6, y: origin.y-3, width: size.width+12, height: size.height+6)) { origin.y = max(10, captureBack.frame.minY-size.height-20) }
            labelBack.frame = CGRect(x: origin.x-6, y: origin.y-3, width: size.width+12, height: size.height+6)
            label.frame = CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
        }
        placeCaptureButton()
        let hex = showMagnifier ? colourUnderPointer() : nil
        for layer in [colourBack, colourSwatch, colourLabel] { layer.isHidden = hex == nil }
        if let hex {
            let text = copiedColour == hex ? "\(hex) copied" : "\(hex)  C"
            let width = (text as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)]).width
            let top = magnifier.frame.maxY + 6, left = magnifier.frame.minX
            colourBack.frame = CGRect(x: left, y: top, width: width + 26, height: 18)
            colourSwatch.frame = CGRect(x: left + 5, y: top + 4, width: 10, height: 10)
            colourSwatch.backgroundColor = NSColor(hex: String(hex.dropFirst())).cgColor
            colourLabel.string = text; colourLabel.frame = CGRect(x: left + 20, y: top + 3, width: width + 2, height: 13)
        }
    }

    private func colourUnderPointer() -> String? {
        guard let snapshot, bounds.width > 0, bounds.height > 0 else { return nil }
        let x = Int(pointer.x * CGFloat(snapshot.width) / bounds.width), y = Int(pointer.y * CGFloat(snapshot.height) / bounds.height)
        return ColorSample.hex(in: snapshot, x: x, y: y)
    }
    /// C copies the colour under the crosshair and keeps it with the recent colours the editor's palette shows. The
    /// selection carries on, so a few can be picked before capturing or pressing Esc.
    private func copyColour() {
        guard let hex = colourUnderPointer() else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hex, forType: .string)
        UserDefaults.standard.set(ColorSample.remember(hex, in: UserDefaults.standard.stringArray(forKey: "recentColors") ?? []), forKey: "recentColors")
        copiedColour = hex; refresh()
    }

    override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); updateHover(); if adjusting { adjustCursor().set() }; refresh() }
    /// The Capture button sits under the box, or above it, or inside its bottom edge when there's no room.
    private func placeCaptureButton() {
        let show = adjusting && grab == nil && region.width > 0 && !coordinator.windowMode
        captureBack.isHidden = !show; captureLabel.isHidden = !show
        guard show else { return }
        let w: CGFloat = 112, h: CGFloat = 32
        var y = region.maxY + 10
        if y + h > bounds.height - 8 { y = region.minY - h - 10 }
        if y < 8 { y = region.maxY - h - 10 }
        let x = max(8, min(bounds.width - w - 8, region.midX - w/2))
        captureBack.frame = CGRect(x: x, y: y, width: w, height: h)
        captureLabel.frame = CGRect(x: x, y: y + 8, width: w, height: 18)
    }
    private func adjustCursor() -> NSCursor {
        if !captureBack.isHidden, captureBack.frame.contains(pointer) { return .arrow }
        switch grab?.handle ?? SelectionGeometry.handle(of: region, at: pointer) {
        case "inside": return grab == nil ? .openHand : .closedHand
        case "n", "s": return .resizeUpDown
        case "e", "w": return .resizeLeftRight
        case .some: return .crosshair
        case .none: return .crosshair
        }
    }
    /// A new area on this display clears a box left being adjusted on another.
    func clearAdjusting() { guard adjusting else { return }; adjusting = false; grab = nil; region = .zero; refresh() }
    /// Scrolling up zooms the magnifier in, scrolling down zooms it out.
    override func scrollWheel(with event: NSEvent) {
        // In window selection, scrolling down goes into the part of the window under the pointer, up back out. One
        // step per notch: a trackpad sends dozens of small scroll events.
        if coordinator.windowMode, hovered != nil, event.scrollingDeltaY != 0 {
            guard event.timestamp - lastPartStep > 0.16, let part = selectedPart() else { return }
            lastPartStep = event.timestamp
            partDepth = max(0, min(part.deepest, part.depth + (event.scrollingDeltaY < 0 ? 1 : -1)))
            refresh(); return
        }
        guard Preferences.shared.magnifier, anchor == nil, !coordinator.windowMode, event.scrollingDeltaY != 0 else { return }
        let steps = SelectionGeometry.magnifierZooms, index = steps.firstIndex(of: magnifierZoom) ?? 4
        magnifierZoom = steps[max(0, min(steps.count-1, index + (event.scrollingDeltaY > 0 ? 1 : -1)))]
        UserDefaults.standard.set(magnifierZoom, forKey: "magnifierZoom")
        refresh()
    }
    override func mouseExited(with event: NSEvent) { pointer = CGPoint(x: -100, y: -100); refresh() }
    override func mouseEntered(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); coordinator.pointerEntered(display); refresh() }
    override func mouseDown(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if coordinator.pickingScreen { coordinator.finish(on: display, rect: CGRect(origin: .zero, size: bounds.size)); return }
        if coordinator.windowMode {
            updateHover()
            // A part of a window is taken like an area; the whole window as a window.
            if let part = selectedPart(), part.depth > 0 { coordinator.finish(on: display, rect: part.rect.intersection(bounds)) }
            else if let hovered { coordinator.capture(window: hovered) }
            return
        }
        if adjusting, region.width > 0 {
            if !captureBack.isHidden, captureBack.frame.contains(pointer) { coordinator.finish(on: display, rect: region); return }
            if event.clickCount >= 2, region.contains(pointer) { coordinator.finish(on: display, rect: region); return }
            if let handle = SelectionGeometry.handle(of: region, at: pointer) { grab = (handle, pointer, region); adjustCursor().set(); refresh(); return }
            adjusting = false // A press outside starts a new area.
        }
        coordinator.clearAdjusting(except: self)
        anchor = pointer; region = .zero; window?.makeFirstResponder(self); refresh()
    }
    /// Space held mid-drag: the selection moves with the pointer, keeping its size, and resizing carries on from its new
    /// place once Space is let go.
    private var moving = false
    func setMoving(_ on: Bool) { guard on != moving else { return }; moving = on; window?.invalidateCursorRects(for: self); refresh() }
    override func mouseDragged(with event: NSEvent) {
        let next = convert(event.locationInWindow, from: nil)
        if let grab {
            pointer = next
            let dx = Double(next.x - grab.from.x), dy = Double(next.y - grab.from.y)
            if grab.handle == "inside" {
                let mx = min(max(CGFloat(dx), -grab.start.minX), bounds.width - grab.start.maxX), my = min(max(CGFloat(dy), -grab.start.minY), bounds.height - grab.start.maxY)
                region = grab.start.offsetBy(dx: mx, dy: my)
            } else {
                region = SelectionGeometry.resize(grab.start, handle: grab.handle, dx: dx, dy: dy, within: bounds, aspect: coordinator.aspect > 0 ? coordinator.aspect : event.modifierFlags.contains(.shift) ? 1 : 0)
            }
            coordinator.width = String(Int(region.width)); coordinator.height = String(Int(region.height)); refresh(); return
        }
        if moving, let anchor, region.width > 0, region.height > 0 {
            let dx = min(max(next.x-pointer.x, -region.minX), bounds.width-region.maxX)
            let dy = min(max(next.y-pointer.y, -region.minY), bounds.height-region.maxY)
            region = region.offsetBy(dx: dx, dy: dy); self.anchor = CGPoint(x: anchor.x+dx, y: anchor.y+dy)
            pointer = next; refresh(); return
        }
        pointer = next
        guard let anchor, !coordinator.windowMode else { refresh(); return }
        let dx = pointer.x-anchor.x, dy = pointer.y-anchor.y
        var size = fixedSize ?? CGSize(width: abs(dx), height: abs(dy))
        if coordinator.aspect > 0 { size.height = size.width/coordinator.aspect }
        if event.modifierFlags.contains(.shift) { size.height = size.width }
        region = CGRect(x: dx >= 0 ? anchor.x : anchor.x-size.width, y: dy >= 0 ? anchor.y : anchor.y-size.height, width: size.width, height: size.height).intersection(bounds)
        refresh()
    }
    override func mouseUp(with event: NSEvent) {
        // Only a press that started a selection here can finish one (a click on empty space in window
        // mode must not capture the remembered area).
        if grab != nil { grab = nil; pointer = convert(event.locationInWindow, from: nil); adjustCursor().set(); refresh(); return }
        guard anchor != nil else { return }
        if region.width <= 2 || region.height <= 2, let fixedSize { region = CGRect(origin: anchor ?? .zero, size: fixedSize).intersection(bounds) }
        if region.width > 2, region.height > 2 {
            coordinator.width = String(Int(region.width)); coordinator.height = String(Int(region.height))
            if Preferences.shared.adjustBeforeCapture { adjusting = true; anchor = nil; moving = false; adjustCursor().set(); refresh(); return }
            coordinator.finish(on: display, rect: region)
        }
        anchor = nil; moving = false; refresh()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { coordinator.cancel(); return }
        // Hold Space to pick a window; releasing it returns to area selection.
        if event.keyCode == 49 {
            if anchor != nil { setMoving(true); return }
            if !event.isARepeat, anchor == nil, !coordinator.windowMode, coordinator.allowsWindowSelection { spaceHeld = true; coordinator.setWindowMode(true) }
            return
        }
        if event.keyCode == 36, region.width > 2 { coordinator.finish(on: display, rect: region); return }
        if [123, 124, 125, 126].contains(event.keyCode) {
            if region.isEmpty { let size = fixedSize ?? CGSize(width: min(640, bounds.width*0.6), height: min(360, bounds.height*0.6)); region = CGRect(x: bounds.midX-size.width/2, y: bounds.midY-size.height/2, width: size.width, height: size.height) }
            let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
            region = SelectionGeometry.move(region, within: bounds, dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0, dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0, resize: event.modifierFlags.contains(.option), aspect: coordinator.aspect)
            coordinator.width = String(Int(region.width)); coordinator.height = String(Int(region.height)); refresh(); return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": coordinator.purpose = .screenshot; coordinator.setWindowMode(false)
        case "w": coordinator.toggleWindowMode()
        case "f": coordinator.fullscreen()
        case "s": coordinator.setWindowMode(false); coordinator.purpose = .scroll
        case "o": coordinator.setWindowMode(false); coordinator.purpose = .text
        case "v": coordinator.setWindowMode(false); coordinator.purpose = .recording
        case "t": coordinator.timer()
        case "c": copyColour()
        default: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { setMoving(false) }
        if event.keyCode == 49, spaceHeld { spaceHeld = false; coordinator.setWindowMode(false); return }
        super.keyUp(with: event)
    }
}

struct CaptureBar: View {
    @ObservedObject var selection: CaptureSelection
    private static let accent = Studio.accent
    var body: some View {
        HStack(spacing: 4) {
            // The Still mark is the bar's handle: drag it to move the bar out of the way. A new capture puts it back.
            Image(nsImage: Studio.menuBarIcon()).renderingMode(.template).foregroundStyle(Self.accent).padding(.leading, 6).padding(.trailing, 4)
                .overlay(BarHandle()).help("Drag to move the Capture Bar").accessibilityLabel("Move the Capture Bar")
            mode("Area", "rectangle.dashed", selected: selection.purpose == .screenshot && !selection.windowMode) { selection.setWindowMode(false); selection.purpose = .screenshot }
            mode("Window", "macwindow", selected: selection.windowMode) { selection.toggleWindowMode() }
            mode("Screen", "display", selected: selection.pickingScreen) { selection.chooseScreen() }
            mode("Scroll", "arrow.down.to.line", selected: selection.purpose == .scroll) { selection.setWindowMode(false); selection.purpose = .scroll }
            divider
            mode("Text", "text.viewfinder", selected: selection.purpose == .text) { selection.setWindowMode(false); selection.purpose = .text }
            mode("Record", "record.circle", selected: selection.purpose == .recording) { selection.setWindowMode(false); selection.purpose = .recording }
            mode("Timer", "timer") { selection.timer() }
            divider
            HStack(spacing: 4) {
                TextField("W", text: $selection.width).frame(width: 40).onSubmit { selection.setDimensions() }.accessibilityLabel("Capture width")
                Text("×").foregroundStyle(.secondary)
                TextField("H", text: $selection.height).frame(width: 40).onSubmit { selection.setDimensions() }.accessibilityLabel("Capture height")
            }.textFieldStyle(.plain).multilineTextAlignment(.center).font(.system(size: 12, design: .monospaced)).padding(.horizontal, 8).frame(height: 28).background(.white.opacity(0.07), in: Capsule())
            Menu { Button("Freeform") { selection.aspect = 0 }; Button("1:1") { selection.aspect = 1 }; Button("4:3") { selection.aspect = 4.0/3 }; Button("16:9") { selection.aspect = 16.0/9 }; Button("9:16") { selection.aspect = 9.0/16 } } label: { Image(systemName: "aspectratio") }.menuStyle(.borderlessButton).fixedSize().frame(width: 30).help("Lock aspect ratio")
        }.padding(.horizontal, 6).frame(height: 44).font(.system(size: 12, weight: .medium))
            .background(.ultraThickMaterial, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.12))).environment(\.colorScheme, .dark).padding(10)
    }
    private var divider: some View { Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 20).padding(.horizontal, 4) }
    private func mode(_ title: String, _ symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: symbol).font(.system(size: 13)); Text(title) }
                .padding(.horizontal, 11).frame(height: 32)
                .foregroundStyle(selected ? Color.white : .primary)
                .background(selected ? Self.accent : .clear, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

/// An invisible patch over the Capture Bar's Still mark that drags the bar's window when pressed.
private struct BarHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { NSCursor.closedHand.push(); window?.performDrag(with: event); NSCursor.pop() }
    }
    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {}
}
