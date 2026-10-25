import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size*scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        NSColor(srgbRed: 0.14, green: 0.19, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 205, yRadius: 205).fill()
        NSColor(srgbRed: 0.85, green: 0.91, blue: 0.68, alpha: 1).setStroke()
        for (x, y, dx, dy) in [(280.0, 280.0, 1.0, 1.0), (744.0, 280.0, -1.0, 1.0), (280.0, 744.0, 1.0, -1.0), (744.0, 744.0, -1.0, -1.0)] {
            let path = NSBezierPath(); path.lineWidth = 50; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: NSPoint(x: x, y: y+dy*105)); path.line(to: NSPoint(x: x, y: y)); path.line(to: NSPoint(x: x+dx*105, y: y)); path.stroke()
        }
        NSColor(srgbRed: 0.96, green: 0.96, blue: 0.91, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 393, y: 413, width: 238, height: 198), xRadius: 28, yRadius: 28).fill()
        NSColor(srgbRed: 0.14, green: 0.19, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 472, y: 472, width: 80, height: 80)).fill()
        image.unlockFocus()
        let data = image.tiffRepresentation!, rep = NSBitmapImageRep(data: data)!
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
