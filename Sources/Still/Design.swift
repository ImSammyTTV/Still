import SwiftUI
import StillCore

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

@MainActor func hexColor(_ binding: Binding<String>) -> Binding<Color> {
    Binding(get: { Color(hex: binding.wrappedValue) }, set: { value in
        guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
        binding.wrappedValue = String(format: "%02X%02X%02X", Int(color.redComponent*255), Int(color.greenComponent*255), Int(color.blueComponent*255))
    })
}
func defaulted<T>(_ binding: Binding<T?>, _ fallback: T) -> Binding<T> { Binding(get: { binding.wrappedValue ?? fallback }, set: { binding.wrappedValue = $0 }) }

/// Still's palette: translucent space grey and white panels over the window's glass, with a graphite accent.
enum Studio {
    /// Graphite: a neutral accent that reads well in light and dark mode.
    static let accent = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: "98989D") : NSColor(hex: "6E6E73") })
    // Slightly translucent, so the window's glass material (see `glass`) shows through.
    static let paper = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: "1C1C1E").withAlphaComponent(0.3) : NSColor(hex: "F6F6F8").withAlphaComponent(0.35) })
    static let surface = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: "3A3A3C").withAlphaComponent(0.45) : NSColor(hex: "FFFFFF").withAlphaComponent(0.55) })
    static let heading = Font.system(size: 26, weight: .semibold)

    /// Puts a view on the native translucent window material, for Still's glassy look.
    /// Borderless panels pass a corner radius, since they have no window frame to round them.
    @MainActor static func glass(_ content: NSView, in window: NSWindow, cornerRadius: CGFloat = 0) -> NSView {
        window.isOpaque = false; window.backgroundColor = .clear
        let material = NSVisualEffectView()
        material.material = .underWindowBackground; material.blendingMode = .behindWindow; material.state = .followsWindowActiveState
        if cornerRadius > 0 { material.wantsLayer = true; material.layer?.cornerRadius = cornerRadius; material.layer?.cornerCurve = .continuous; material.layer?.masksToBounds = true }
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: material.leadingAnchor), content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                                     content.topAnchor.constraint(equalTo: material.topAnchor), content.bottomAnchor.constraint(equalTo: material.bottomAnchor)])
        return material
    }

    /// The logo's own artwork (frame, gaps and curled corner) as a template, so macOS draws it black or white.
    @MainActor static func menuBarIcon() -> NSImage {
        let image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil) ?? NSImage()
        image.accessibilityDescription = "Still capture menu"
        image.isTemplate = true
        return image
    }
}
