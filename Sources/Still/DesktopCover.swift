import AppKit
import SwiftUI

@MainActor final class DesktopCover {
    static let shared = DesktopCover()
    private var panels: [NSPanel] = []
    private var transient = 0
    private var manual = false
    var windowIDs: Set<CGWindowID> { Set(panels.map { CGWindowID($0.windowNumber) }) }
    func beginCapture() { if Preferences.shared.hideDesktop { transient += 1; update() } }
    func endCapture() { transient = max(0, transient-1); update() }
    func toggle() { manual.toggle(); update() }
    func reset() { transient = 0; manual = false; update() }
    func backgroundData(for screen: NSScreen?) -> Data? {
        let prefs = Preferences.shared
        if prefs.wallpaperMode == "color" { return nil }
        let url = prefs.wallpaperMode == "image" ? URL(fileURLWithPath: prefs.wallpaperImage) : screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        return url.flatMap { try? Data(contentsOf: $0) }
    }
    private func update() {
        guard manual || transient > 0 else { panels.forEach { $0.close() }; panels = []; return }
        guard panels.isEmpty else { return }
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow))+1)
            panel.ignoresMouseEvents = true; panel.isOpaque = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let prefs = Preferences.shared
            let url = prefs.wallpaperMode == "image" ? URL(fileURLWithPath: prefs.wallpaperImage) : NSWorkspace.shared.desktopImageURL(for: screen)
            let image = prefs.wallpaperMode == "color" ? nil : url.flatMap { NSImage(contentsOf: $0) }
            panel.contentView = NSHostingView(rootView: DesktopWallpaper(image: image, color: Color(hex: prefs.wallpaperColor)))
            panel.orderFrontRegardless(); panels.append(panel)
        }
    }
}
struct DesktopWallpaper: View {
    let image: NSImage?
    let color: Color
    var body: some View { GeometryReader { geometry in if let image { Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() } else { color } }.ignoresSafeArea() }
}
