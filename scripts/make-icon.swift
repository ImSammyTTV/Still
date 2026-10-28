import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size*scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        NSColor(hex: "242522").setFill()
        NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 190, yRadius: 190).fill()
        NSColor(hex: "9C998D").setFill()
        NSBezierPath(roundedRect: NSRect(x: 238, y: 228, width: 480, height: 540), xRadius: 12, yRadius: 12).fill()
        NSColor(hex: "F4F0E7").setFill()
        NSBezierPath(roundedRect: NSRect(x: 302, y: 292, width: 480, height: 540), xRadius: 12, yRadius: 12).fill()
        NSColor(hex: "D64B32").setFill()
        NSBezierPath(ovalIn: NSRect(x: 514, y: 480, width: 144, height: 144)).fill()
        NSColor(hex: "242522").setFill()
        NSBezierPath(rect: NSRect(x: 366, y: 368, width: 170, height: 13)).fill()
        image.unlockFocus()
        let data = image.tiffRepresentation!, rep = NSBitmapImageRep(data: data)!
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

extension NSColor {
    convenience init(hex: String) {
        let n = UInt32(hex, radix: 16) ?? 0
        self.init(srgbRed: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255, alpha: 1)
    }
}
