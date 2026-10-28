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

/// Still's studio palette adapts to the user's appearance preference.
enum Studio {
    static let accent = Color(hex: "D64B32")
    static let paper = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: "242522") : NSColor(hex: "F4F0E7") })
    static let surface = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: "30312C") : NSColor(hex: "FFFCF5") })
    static let heading = Font.custom("Baskerville", size: 30)
}
