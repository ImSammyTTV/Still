import AppKit
import SwiftUI
import ScreenCaptureKit
import StillCore

enum SelectionPurpose { case screenshot, text, scroll, recording }
@MainActor enum ScreenCaptureAPI {
    static func filter(screen: NSScreen) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw NSError(domain: "Still", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected display is no longer connected."]) }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
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
        Task {
            do {
                for screen in NSScreen.screens {
                    let image = try await ScreenCaptureAPI.image(screen: screen)
                    images[ObjectIdentifier(screen)] = image
                }
                for screen in NSScreen.screens {
                    guard let image = images[ObjectIdentifier(screen)] else { continue }
                    let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.title = "Capture Selection"
                    panel.level = .screenSaver; panel.backgroundColor = .clear; panel.isOpaque = false
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.acceptsMouseMovedEvents = true
                    let view = SelectionSurface(image: image, screen: screen, coordinator: self)
                    view.frame = CGRect(origin: .zero, size: screen.frame.size)
                    panel.contentView = view; panels.append(panel); views.append(view)
                    panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
                }
                showBar(); NSApp.activate(ignoringOtherApps: true)
            } catch { close(); onError?(error) }
        }
    }
    private func showBar() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let panel = SelectionPanel(contentRect: CGRect(x: screen.frame.midX-380, y: screen.visibleFrame.minY+70, width: 760, height: 66), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "All-In-One"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue+1); panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: CaptureBar(selection: self))
        panel.orderFrontRegardless(); bar = panel
    }
    func setDimensions() {
        guard let width = Double(width), let height = Double(height), width > 1, height > 1 else { return }
        for view in views { view.fixedSize = CGSize(width: min(width, view.bounds.width), height: min(height, view.bounds.height)); view.needsDisplay = true }
    }
    func finish(on screen: NSScreen, rect: CGRect) {
        guard active, let source = images[ObjectIdentifier(screen)] else { return }
        let purpose = self.purpose
        let scaleX = CGFloat(source.width)/screen.frame.width, scaleY = CGFloat(source.height)/screen.frame.height
        let crop = CGRect(x: rect.minX*scaleX, y: rect.minY*scaleY, width: rect.width*scaleX, height: rect.height*scaleY)
        if Preferences.shared.rememberSelection {
            UserDefaults.standard.set(["screen": (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.doubleValue ?? 0, "x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height], forKey: "lastSelection")
        }
        close()
        Task {
            do {
                let image: CGImage
                if Preferences.shared.freezeScreen || purpose == .scroll || purpose == .recording { image = try ImageRenderer.crop(source, to: crop) }
                else { try await Task.sleep(nanoseconds: 140_000_000); image = try await ScreenCaptureAPI.image(screen: screen, rect: rect) }
                onSelected?(image, screen, rect, purpose)
            } catch { onError?(error) }
        }
    }
    func fullscreen() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        finish(on: screen, rect: CGRect(origin: .zero, size: screen.frame.size))
    }
    func window() { close(); onCancel?(); DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { AppController.shared.capture(.window) } }
    func toggleWindowMode() { guard purpose == .screenshot else { return }; windowMode.toggle(); views.forEach { $0.windowModeChanged() } }
    func capture(window: OverlayWindow) { close(); onCancel?(); DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { AppController.shared.capture(.window, windowID: window.id) } }
    func timer() { close(); onCancel?(); DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { AppController.shared.capture(.area, delay: 5) } }
    func cancel() { close(); onCancel?() }
    func close() { active = false; for panel in panels { panel.close() }; panels = []; views = []; images = [:]; bar?.close(); bar = nil }
}
/// A normal-layer window from the Window Server list, front to back, in global top-left coordinates.
struct OverlayWindow {
    let id: CGWindowID
    let frame: CGRect
    static func onScreen() -> [OverlayWindow] {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? pid_t) != own,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 40, frame.height > 40,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0 else { return nil }
            return OverlayWindow(id: id, frame: frame)
        }
    }
}
final class SelectionPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }

@MainActor final class SelectionSurface: NSView {
    let image: CGImage
    let display: NSScreen
    unowned let coordinator: CaptureSelection
    var fixedSize: CGSize?
    private var anchor: CGPoint?
    private var pointer = CGPoint.zero
    private var region = CGRect.zero
    private var hovered: OverlayWindow?
    override var isFlipped: Bool { true }
    /// Converts a global top-left window frame into this screen's flipped view coordinates.
    private func local(_ frame: CGRect) -> CGRect {
        let primary = NSScreen.screens.first?.frame.height ?? display.frame.height
        return frame.offsetBy(dx: -display.frame.minX, dy: -(primary-display.frame.maxY))
    }
    private func updateHover() {
        hovered = coordinator.windowMode ? coordinator.windows.first(where: { local($0.frame).contains(pointer) }) : nil
    }
    func windowModeChanged() { anchor = nil; updateHover(); window?.invalidateCursorRects(for: self); needsDisplay = true }
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage, screen: NSScreen, coordinator: CaptureSelection) { self.image = image; self.display = screen; self.coordinator = coordinator; super.init(frame: .zero)
        if Preferences.shared.rememberSelection, let saved = UserDefaults.standard.dictionary(forKey: "lastSelection"), let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.doubleValue, (saved["screen"] as? Double) == id, let x = saved["x"] as? Double, let y = saved["y"] as? Double, let w = saved["w"] as? Double, let h = saved["h"] as? Double {
            region = CGRect(x: x,y: y,width: w,height: h).intersection(CGRect(origin: .zero,size: screen.frame.size))
            coordinator.width = String(Int(region.width)); coordinator.height = String(Int(region.height))
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)) }
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
    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: display.frame.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if coordinator.windowMode { drawWindowMode(); return }
        let shade = NSBezierPath(rect: bounds)
        if region.width > 0 { shade.append(NSBezierPath(rect: region)); shade.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.28).setFill(); shade.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        if region.width > 0 { let border = NSBezierPath(rect: region); border.lineWidth = 1; border.stroke() }
        if Preferences.shared.crosshair != "disabled" {
            let path = NSBezierPath(); path.lineWidth = 0.5
            if Preferences.shared.crosshair == "full" { path.move(to: CGPoint(x: pointer.x, y: 0)); path.line(to: CGPoint(x: pointer.x, y: bounds.height)); path.move(to: CGPoint(x: 0, y: pointer.y)); path.line(to: CGPoint(x: bounds.width, y: pointer.y)) }
            else { path.move(to: CGPoint(x: pointer.x-20, y: pointer.y)); path.line(to: CGPoint(x: pointer.x+20, y: pointer.y)); path.move(to: CGPoint(x: pointer.x, y: pointer.y-20)); path.line(to: CGPoint(x: pointer.x, y: pointer.y+20)) }
            path.stroke()
        }
        let label = region.width > 0 ? "\(Int(region.width)) × \(Int(region.height))" : "Drag to select an area · Esc to cancel"
        let point = CGPoint(x: min(bounds.width-220, max(10, pointer.x+18)), y: min(bounds.height-35, max(10, pointer.y+18)))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attributes)
        NSColor.black.withAlphaComponent(0.7).setFill(); NSBezierPath(roundedRect: CGRect(x: point.x-6, y: point.y-4, width: size.width+12, height: size.height+8), xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(at: point, withAttributes: attributes)
        if Preferences.shared.magnifier, anchor == nil {
            let scale = CGFloat(image.width)/bounds.width
            let crop = CGRect(x: pointer.x*scale-8, y: pointer.y*scale-8, width: 16, height: 16).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if crop.width > 0, let patch = image.cropping(to: crop) {
                let box = CGRect(x: min(bounds.width-90, max(10, pointer.x+24)), y: max(10, pointer.y-100), width: 80, height: 80)
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).addClip()
                NSImage(cgImage: patch, size: .zero).draw(in: box, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none]); NSGraphicsContext.restoreGraphicsState()
                NSColor.white.setStroke(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).stroke()
            }
        }
    }
    private func drawWindowMode() {
        NSColor.black.withAlphaComponent(0.12).setFill(); bounds.fill()
        if let hovered {
            let frame = local(hovered.frame).intersection(bounds)
            NSColor.systemBlue.withAlphaComponent(0.32).setFill(); frame.fill()
            NSColor.systemBlue.withAlphaComponent(0.8).setStroke(); let border = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
        }
        let label = hovered == nil ? "Move over a window · Space for area · Esc to cancel" : "Click to capture window · Space for area"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attributes)
        let point = CGPoint(x: min(bounds.width-size.width-16, max(10, pointer.x+18)), y: min(bounds.height-35, max(10, pointer.y+18)))
        NSColor.black.withAlphaComponent(0.7).setFill(); NSBezierPath(roundedRect: CGRect(x: point.x-6, y: point.y-4, width: size.width+12, height: size.height+8), xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(at: point, withAttributes: attributes)
    }
    override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); updateHover(); needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        if coordinator.windowMode { pointer = convert(event.locationInWindow, from: nil); updateHover(); if let hovered { coordinator.capture(window: hovered) }; return }
        anchor = convert(event.locationInWindow, from: nil); region = .zero; window?.makeFirstResponder(self)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor, !coordinator.windowMode else { return }
        pointer = convert(event.locationInWindow, from: nil)
        let dx = pointer.x-anchor.x, dy = pointer.y-anchor.y
        var size = fixedSize ?? CGSize(width: abs(dx), height: abs(dy))
        if coordinator.aspect > 0 { size.height = size.width/coordinator.aspect }
        if event.modifierFlags.contains(.shift) { size.height = size.width }
        region = CGRect(x: dx >= 0 ? anchor.x : anchor.x-size.width, y: dy >= 0 ? anchor.y : anchor.y-size.height, width: size.width, height: size.height).intersection(bounds)
        coordinator.width = String(Int(region.width)); coordinator.height = String(Int(region.height)); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { if region.width > 2, region.height > 2 { coordinator.finish(on: display, rect: region) } else if let fixedSize { coordinator.finish(on: display, rect: CGRect(origin: anchor ?? .zero, size: fixedSize).intersection(bounds)) }; anchor = nil }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { coordinator.cancel(); return }
        if event.keyCode == 49 { if anchor == nil { coordinator.toggleWindowMode() }; return }
        if event.keyCode == 36, region.width > 2 { coordinator.finish(on: display,rect: region); return }
        if [123,124,125,126].contains(event.keyCode) {
            if region.isEmpty { let size = fixedSize ?? CGSize(width: min(640,bounds.width*0.6),height: min(360,bounds.height*0.6)); region = CGRect(x: bounds.midX-size.width/2,y: bounds.midY-size.height/2,width: size.width,height: size.height) }
            let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
            region = SelectionGeometry.move(region,within: bounds,dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0,resize: event.modifierFlags.contains(.option),aspect: coordinator.aspect)
            coordinator.width = String(Int(region.width)); coordinator.height = String(Int(region.height)); needsDisplay = true; return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": coordinator.purpose = .screenshot
        case "w": coordinator.toggleWindowMode()
        case "f": coordinator.fullscreen()
        case "s": coordinator.purpose = .scroll
        case "o": coordinator.purpose = .text
        case "v": coordinator.purpose = .recording
        case "t": coordinator.timer()
        default: super.keyDown(with: event)
        }
    }
}

struct CaptureBar: View {
    @ObservedObject var selection: CaptureSelection
    var body: some View {
        HStack(spacing: 0) {
            mode("Area", "viewfinder", selected: selection.purpose == .screenshot) { selection.purpose = .screenshot }
            mode("Fullscreen", "display") { selection.fullscreen() }
            mode("Window", "macwindow", selected: selection.windowMode) { selection.toggleWindowMode() }
            mode("Scrolling", "arrow.down.to.line", selected: selection.purpose == .scroll) { selection.purpose = .scroll }
            mode("Timer", "timer") { selection.timer() }
            Divider().frame(height: 34)
            mode("OCR", "textformat", selected: selection.purpose == .text) { selection.purpose = .text }
            mode("Recording", "video", selected: selection.purpose == .recording) { selection.purpose = .recording }
            Divider().frame(height: 34).padding(.horizontal, 9)
            TextField("Width", text: $selection.width).frame(width: 48).textFieldStyle(.plain).multilineTextAlignment(.center).padding(.vertical, 6).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5)).onSubmit { selection.setDimensions() }.accessibilityLabel("Capture width")
            Text("×").foregroundStyle(.secondary).padding(.horizontal, 5)
            TextField("Height", text: $selection.height).frame(width: 48).textFieldStyle(.plain).multilineTextAlignment(.center).padding(.vertical, 6).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5)).onSubmit { selection.setDimensions() }.accessibilityLabel("Capture height")
            Menu { Button("Freeform") { selection.aspect = 0 }; Button("1:1") { selection.aspect = 1 }; Button("4:3") { selection.aspect = 4.0/3 }; Button("16:9") { selection.aspect = 16.0/9 }; Button("9:16") { selection.aspect = 9.0/16 } } label: { Image(systemName: "aspectratio").frame(width: 28) }.menuStyle(.borderlessButton).fixedSize().help("Lock aspect ratio")
        }.padding(.horizontal, 10).frame(height: 62).font(.system(size: 12)).background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1))).environment(\.colorScheme, .dark)
    }
    private func mode(_ title: String, _ symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View { Button(action: action) { VStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 15)); Text(title).font(.system(size: 10)).foregroundStyle(.secondary) }.frame(width: 69, height: 51).background(selected ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).accessibilityLabel(title) }
}
