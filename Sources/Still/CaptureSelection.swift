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
    @Published var purpose = SelectionPurpose.screenshot
    /// Space toggles between dragging an area and clicking a window, like the system screenshot overlay.
    @Published var windowMode = false
    private(set) var windows: [OverlayWindow] = []
    private var panels: [NSPanel] = []
    private var bar: NSPanel?
    private var images: [ObjectIdentifier: CGImage] = [:]
    private var views: [SelectionSurface] = []
    private var active = false
    var onSelected: ((CGImage, NSScreen, CGRect, SelectionPurpose) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?
    func begin(_ purpose: SelectionPurpose) {
        guard !active else { return }
        self.purpose = purpose; active = true; windowMode = false; windows = OverlayWindow.onScreen()
        // Grab every display first, before Still takes focus, so open menus, Spotlight and hover states
        // are in the picture. The overlay then sits on that frozen image, like the system tool.
        Task {
            var shots: [ObjectIdentifier: CGImage] = [:]
            var failures: [String] = []
            let grabs = await ScreenCaptureAPI.images(screens: NSScreen.screens)
            for screen in NSScreen.screens {
                do { shots[ObjectIdentifier(screen)] = try grabs[ObjectIdentifier(screen)]?.get() }
                catch { let error = error as NSError; failures.append("\(screen.localizedName): \(error.localizedDescription) (\(error.domain) \(error.code))") }
            }
            guard active else { return }
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
        _ = FirstClickHostingView(rootView: CaptureBar(selection: self)).fittingSize
        let panel = SelectionPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = SelectionSurface(screen: screen, coordinator: self); panel.contentView?.layoutSubtreeIfNeeded()
    }
    /// Still's capture bar: a slim pill along the bottom of the screen the pointer is on.
    private func showBar() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let host = FirstClickHostingView(rootView: CaptureBar(selection: self))
        let size = host.fittingSize
        let panel = SelectionPanel(contentRect: CGRect(x: screen.frame.midX-size.width/2, y: screen.visibleFrame.minY+28, width: size.width, height: size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Capture Bar"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue+1); panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = host; panel.hidesOnDeactivate = false
        panel.orderFrontRegardless(); bar = panel
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
    func fullscreen() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        finish(on: screen, rect: CGRect(origin: .zero, size: screen.frame.size))
    }
    func window() { close(); onCancel?(); DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { AppController.shared.capture(.window) } }
    func toggleWindowMode() { setWindowMode(!windowMode) }
    func setWindowMode(_ on: Bool) { guard purpose == .screenshot || !on, on != windowMode else { return }; windowMode = on; views.forEach { $0.windowModeChanged() } }
    func capture(window: OverlayWindow) {
        if window.popup, let primary = NSScreen.screens.first,
           let screen = NSScreen.screens.first(where: { CGRect(x: $0.frame.minX, y: primary.frame.maxY-$0.frame.maxY, width: $0.frame.width, height: $0.frame.height).intersects(window.frame) }) {
            let local = CGRect(x: window.frame.minX-screen.frame.minX, y: window.frame.minY-(primary.frame.maxY-screen.frame.maxY), width: window.frame.width, height: window.frame.height)
            finish(on: screen, rect: local.intersection(CGRect(origin: .zero, size: screen.frame.size))); return
        }
        close(); onCancel?(); DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { AppController.shared.capture(.window, windowID: window.id) } }
    func timer() { close(); onCancel?(); DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { AppController.shared.capture(.area, delay: 5) } }
    func cancel() { close(); onCancel?() }
    func close() { active = false; for panel in panels { panel.close() }; panels = []; views = []; images = [:]; bar?.close(); bar = nil }
}
/// A normal-layer window from the Window Server list, front to back, in global top-left coordinates.
struct OverlayWindow {
    let id: CGWindowID
    let frame: CGRect
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
            return OverlayWindow(id: id, frame: frame, popup: layer > 0)
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
    private var pointer = CGPoint(x: -100, y: -100)
    private var region = CGRect.zero
    private var hovered: OverlayWindow?
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
        for layer in [frozen, shade, highlight, border, crossH, crossV, magnifier, labelBack, label] as [CALayer] { layer.actions = Self.noAnimations; root.addSublayer(layer) }
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: coordinator.windowMode ? Self.cameraCursor : .crosshair) }
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
    private func updateHover() { hovered = coordinator.windowMode ? coordinator.windows.first(where: { local($0.frame).contains(pointer) }) : nil }
    func windowModeChanged() { anchor = nil; updateHover(); window?.invalidateCursorRects(for: self); refresh() }

    func refresh() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let windowMode = coordinator.windowMode
        let onScreen = bounds.contains(pointer)
        // Area mode: dim only outside the selection, like the system tool; window mode: blue highlight.
        let hasRegion = !windowMode && region.width > 0
        shade.isHidden = !hasRegion
        if hasRegion { let path = CGMutablePath(); path.addRect(bounds); path.addRect(region); shade.path = path; border.path = CGPath(rect: region.insetBy(dx: 0.5, dy: 0.5), transform: nil) }
        border.isHidden = !hasRegion
        if windowMode, let hovered { highlight.frame = local(hovered.frame).intersection(bounds); highlight.isHidden = false } else { highlight.isHidden = true }
        let crosshair = Preferences.shared.crosshair
        let showCross = !windowMode && onScreen && crosshair != "disabled"
        crossH.isHidden = !showCross; crossV.isHidden = !showCross
        if showCross {
            let px = 1/display.backingScaleFactor
            if crosshair == "full" { crossH.frame = CGRect(x: 0, y: pointer.y, width: bounds.width, height: px); crossV.frame = CGRect(x: pointer.x, y: 0, width: px, height: bounds.height) }
            else { crossH.frame = CGRect(x: pointer.x-20, y: pointer.y, width: 40, height: px); crossV.frame = CGRect(x: pointer.x, y: pointer.y-20, width: px, height: 40) }
        }
        let text: String
        if windowMode { text = hovered == nil ? "Hold Space and move over a window" : "Click to capture window" }
        else if region.width > 0 { text = "\(Int(region.width)) × \(Int(region.height))" }
        else { text = "" }
        label.isHidden = text.isEmpty || !onScreen; labelBack.isHidden = label.isHidden
        if !label.isHidden {
            label.string = text
            let size = (text as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)])
            let origin = CGPoint(x: min(bounds.width-size.width-18, max(10, pointer.x+16)), y: min(bounds.height-30, max(10, pointer.y+16)))
            labelBack.frame = CGRect(x: origin.x-6, y: origin.y-3, width: size.width+12, height: size.height+6)
            label.frame = CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
        }
        let showMagnifier = Preferences.shared.magnifier && !windowMode && anchor == nil && onScreen && snapshot != nil
        magnifier.isHidden = !showMagnifier
        if showMagnifier, let snapshot {
            let w = CGFloat(snapshot.width), h = CGFloat(snapshot.height), sx = w/bounds.width, sy = h/bounds.height
            let patch: CGFloat = 13
            magnifier.contentsRect = CGRect(x: (pointer.x*sx-patch/2)/w, y: (pointer.y*sy-patch/2)/h, width: patch/w, height: patch/h)
            magnifier.frame = CGRect(x: min(bounds.width-100, pointer.x+22), y: max(10, pointer.y-110), width: 88, height: 88)
        }
    }

    override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); updateHover(); refresh() }
    override func mouseExited(with event: NSEvent) { pointer = CGPoint(x: -100, y: -100); refresh() }
    override func mouseDown(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if coordinator.windowMode { updateHover(); if let hovered { coordinator.capture(window: hovered) }; return }
        anchor = pointer; region = .zero; window?.makeFirstResponder(self); refresh()
    }
    override func mouseDragged(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
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
        guard anchor != nil else { return }
        if region.width > 2, region.height > 2 { coordinator.width = String(Int(region.width)); coordinator.height = String(Int(region.height)); coordinator.finish(on: display, rect: region) }
        else if let fixedSize { coordinator.finish(on: display, rect: CGRect(origin: anchor ?? .zero, size: fixedSize).intersection(bounds)) }
        anchor = nil; refresh()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { coordinator.cancel(); return }
        // Hold Space to pick a window; releasing it returns to area selection.
        if event.keyCode == 49 {
            if !event.isARepeat, anchor == nil, !coordinator.windowMode, coordinator.purpose == .screenshot { spaceHeld = true; coordinator.setWindowMode(true) }
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
        default: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, spaceHeld { spaceHeld = false; coordinator.setWindowMode(false); return }
        super.keyUp(with: event)
    }
}

struct CaptureBar: View {
    @ObservedObject var selection: CaptureSelection
    private static let accent = Studio.accent
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "viewfinder").font(.system(size: 13, weight: .semibold)).foregroundStyle(Self.accent).padding(.leading, 6).padding(.trailing, 4)
            mode("Area", "rectangle.dashed", selected: selection.purpose == .screenshot && !selection.windowMode) { selection.setWindowMode(false); selection.purpose = .screenshot }
            mode("Window", "macwindow", selected: selection.windowMode) { selection.toggleWindowMode() }
            mode("Screen", "display") { selection.fullscreen() }
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


