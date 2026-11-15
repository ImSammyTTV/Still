import AppKit
import SwiftUI
import ImageIO

@MainActor final class DesktopCover {
    static let shared = DesktopCover()
    private var panels: [NSPanel] = []
    /// What the panels were made for (each screen's frame and wallpaper, and the colour), so the next capture shows
    /// the same panels again instead of reading and drawing the wallpaper all over.
    private var panelsMadeFor: [String] = []
    private var transient = 0
    private var manual = false
    var windowIDs: Set<CGWindowID> { Set(panels.filter(\.isVisible).map { CGWindowID($0.windowNumber) }) }
    func beginCapture() { if Preferences.shared.hideDesktop { transient += 1; update() } }
    func endCapture() { transient = max(0, transient-1); update() }
    func toggle() { manual.toggle(); update() }
    func reset() { transient = 0; manual = false; update() }
    /// The wallpaper file's bytes, kept while the file stays the same: a window capture with a background asks on
    /// every capture, and a wallpaper can be tens of megabytes.
    private var backgroundFile: (key: String, data: Data)?
    func backgroundData(for screen: NSScreen?) -> Data? {
        let prefs = Preferences.shared
        if prefs.wallpaperMode == "color" { return nil }
        guard let url = prefs.wallpaperMode == "image" ? URL(fileURLWithPath: prefs.wallpaperImage) : screen.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }) else { return nil }
        let key = Self.fileKey(url)
        if let saved = backgroundFile, saved.key == key { return saved.data }
        guard let data = try? Data(contentsOf: url) else { return nil }
        backgroundFile = (key, data)
        return data
    }
    /// A file's path and when it last changed, so a wallpaper replaced in place is read again.
    private static func fileKey(_ url: URL) -> String {
        let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(changed)"
    }
    /// Each screen's wallpaper, decoded once at that screen's size and kept while the file and screen stay the same.
    private var wallpapers: [String: NSImage] = [:]
    private func wallpaper(_ url: URL, for screen: NSScreen, key: String) -> NSImage? {
        if let cached = wallpapers[key] { return cached }
        // A little over the screen's size, so filling a screen of another shape still looks sharp.
        let side = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor * 1.25)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(1, side), kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return NSImage(contentsOf: url) }
        let decoded = NSImage(cgImage: image, size: .zero)
        wallpapers[key] = decoded
        return decoded
    }
    private func update() {
        guard manual || transient > 0 else {
            // Hidden, not closed: the next capture shows the same panels straight away.
            panels.forEach { $0.orderOut(nil) }
            return
        }
        let prefs = Preferences.shared
        let screens = NSScreen.screens
        let urls: [URL?] = screens.map { screen in
            if prefs.wallpaperMode == "color" { return nil }
            return prefs.wallpaperMode == "image" ? URL(fileURLWithPath: prefs.wallpaperImage) : NSWorkspace.shared.desktopImageURL(for: screen)
        }
        var keys: [String] = []
        for (screen, url) in zip(screens, urls) {
            let file = url.map { Self.fileKey($0) } ?? "none"
            keys.append("\(NSStringFromRect(screen.frame))@\(screen.backingScaleFactor)|\(file)|\(prefs.wallpaperColor)")
        }
        if keys == panelsMadeFor, panels.count == screens.count {
            panels.forEach { $0.orderFrontRegardless() }
            return
        }
        panels.forEach { $0.close() }; panels = []
        // Only the wallpapers on screen now are kept.
        wallpapers = wallpapers.filter { keys.contains($0.key) }
        for (index, screen) in screens.enumerated() {
            let panel = NSPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow))+1)
            panel.ignoresMouseEvents = true; panel.isOpaque = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let image = urls[index].flatMap { wallpaper($0, for: screen, key: keys[index]) }
            panel.contentView = NSHostingView(rootView: DesktopWallpaper(image: image, color: Color(hex: prefs.wallpaperColor)))
            panel.orderFrontRegardless(); panels.append(panel)
        }
        panelsMadeFor = keys
    }
}
struct DesktopWallpaper: View {
    let image: NSImage?
    let color: Color
    var body: some View { GeometryReader { geometry in if let image { Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() } else { color } }.ignoresSafeArea() }
}
