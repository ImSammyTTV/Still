import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size*scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 192, yRadius: 192)
        NSGradient(starting: NSColor(hex: "FFFFFF"), ending: NSColor(hex: "F0F1F3"))!.draw(in: tile, angle: -90)
        NSColor(hex: "DDE0E3").setStroke(); tile.lineWidth = 2; tile.stroke()
        let frame = NSBezierPath(roundedRect: NSRect(x: 228, y: 326, width: 568, height: 372), xRadius: 20, yRadius: 20)
        NSColor(hex: "24272B").setStroke(); frame.lineWidth = 40; frame.stroke()
        // A lifted screenshot corner: a single white flap with a restrained underside.
        NSColor(hex: "D5D8DC").setFill()
        let underneath = NSBezierPath(); underneath.move(to: NSPoint(x: 666, y: 306)); underneath.line(to: NSPoint(x: 816, y: 306)); underneath.line(to: NSPoint(x: 816, y: 456)); underneath.close(); underneath.fill()
        let flap = NSBezierPath(); flap.move(to: NSPoint(x: 660, y: 306)); flap.curve(to: NSPoint(x: 684, y: 346), controlPoint1: NSPoint(x: 678, y: 310), controlPoint2: NSPoint(x: 684, y: 326)); flap.line(to: NSPoint(x: 684, y: 428)); flap.curve(to: NSPoint(x: 708, y: 452), controlPoint1: NSPoint(x: 684, y: 444), controlPoint2: NSPoint(x: 692, y: 452)); flap.line(to: NSPoint(x: 792, y: 452)); flap.curve(to: NSPoint(x: 816, y: 470), controlPoint1: NSPoint(x: 805, y: 452), controlPoint2: NSPoint(x: 814, y: 459)); flap.curve(to: NSPoint(x: 660, y: 306), controlPoint1: NSPoint(x: 808, y: 428), controlPoint2: NSPoint(x: 698, y: 320)); flap.close()
        NSGradient(starting: NSColor(hex: "FFFFFF"), ending: NSColor(hex: "E8EAED"))!.draw(in: flap, angle: -45)
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
