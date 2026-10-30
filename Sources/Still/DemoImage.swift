import AppKit
import StillCore

enum DemoImage {
    static func make() -> CGImage {
        let size = NSSize(width: 1200, height: 760)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(hex: "E8E8ED").setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor(hex: "FFFFFF").setFill(); NSBezierPath(roundedRect: NSRect(x: 100, y: 90, width: 1000, height: 580), xRadius: 20, yRadius: 20).fill()
        for (idx, color) in ["E8AB9C", "E6D39D", "B6C9A5"].enumerated() {
            NSColor(hex: color).setFill(); NSBezierPath(ovalIn: NSRect(x: 130+idx*23, y: 630, width: 13, height: 13)).fill()
        }
        text("A LITTLE FIELD GUIDE", x: 150, y: 555, font: "AvenirNext-DemiBold", size: 14, hex: "6E6E73")
        text("Make your point.", x: 145, y: 453, font: "Georgia", size: 62, hex: "1D1D1F")
        text("A screenshot is worth a thousand explanations.", x: 150, y: 408, font: "AvenirNext-Regular", size: 21, hex: "6E6E73")
        text("01    Draw an arrow to the detail that matters.", x: 150, y: 325, font: "AvenirNext-Medium", size: 21, hex: "1D1D1F")
        text("02    Highlight the important part, add a note, or crop.", x: 150, y: 275, font: "AvenirNext-Medium", size: 21, hex: "1D1D1F")
        text("03    Copy it. Save it. Keep moving.", x: 150, y: 225, font: "AvenirNext-Medium", size: 21, hex: "1D1D1F")
        NSColor(hex: "F2F2F5").setFill(); NSBezierPath(roundedRect: NSRect(x: 150, y: 130, width: 900, height: 56), xRadius: 8, yRadius: 8).fill()
        text("Try redacting this:  example@still.local", x: 170, y: 147, font: "AvenirNext-Regular", size: 18, hex: "515154")
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
    private static func text(_ string: String, x: CGFloat, y: CGFloat, font: String, size: CGFloat, hex: String) {
        (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont(name: font, size: size) ?? .systemFont(ofSize: size), .foregroundColor: NSColor(hex: hex)])
    }
}
