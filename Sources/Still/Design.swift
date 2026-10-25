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
