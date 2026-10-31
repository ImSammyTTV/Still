import CoreGraphics
import CoreText
import Foundation

/// The watermark: a line of your own text (a name, a handle, "Draft") laid over every picture the editor copies, saves
/// or shares. It's sized from the picture's shorter side, so it reads the same on a small crop and a full screen.
/// Windows and Linux follow the same rules (shared/watermark.js) and share the test cases.
public struct Watermark: Equatable {
    public static let positions = ["bottomRight", "bottomLeft", "topRight", "topLeft", "center"]
    public static let sizes: [String: Double] = ["small": 0.022, "medium": 0.032, "large": 0.048]

    public var text: String
    public var position: String
    public var size: String
    public var opacity: Double

    /// The saved setting, tidied; nil when there's no text, which means no watermark.
    public init?(text: String, position: String = "bottomRight", size: String = "medium", opacity: Double = 0.7) {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !text.isEmpty else { return nil }
        self.text = text
        self.position = Self.positions.contains(position) ? position : "bottomRight"
        self.size = Self.sizes[size] != nil ? size : "medium"
        self.opacity = min(1, max(0.1, opacity.isFinite && opacity > 0 ? opacity : 0.7))
    }

    public struct Placement: Equatable {
        public var fontSize: Double, margin: Double, x: Double, y: Double
        /// How the text hangs from (x, y): 0 = left / top, 0.5 = middle, 1 = right / bottom.
        public var alignX: Double, alignY: Double
    }

    /// Font size and the point the text hangs from, measured from the top left.
    public func placement(width: Double, height: Double) -> Placement {
        let fontSize = (min(96, max(11, min(width, height) * Self.sizes[size]!))).rounded()
        let margin = (fontSize * 0.9).rounded()
        let alignX = position == "center" ? 0.5 : position.hasSuffix("Right") ? 1 : 0
        let alignY = position == "center" ? 0.5 : position.hasPrefix("bottom") ? 1 : 0
        let x = alignX == 0.5 ? width / 2 : alignX == 1 ? width - margin : margin
        let y = alignY == 0.5 ? height / 2 : alignY == 1 ? height - margin : margin
        return Placement(fontSize: fontSize, margin: margin, x: x, y: y, alignX: alignX, alignY: alignY)
    }

    /// The picture with the watermark drawn on: white text with a soft dark shadow, so it reads on light and dark
    /// pictures alike.
    public func apply(to image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let at = placement(width: Double(width), height: Double(height))
        let font = CTFontCreateUIFontForLanguage(.system, at.fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, at.fontSize, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(font, at.fontSize, nil, .boldTrait, .boldTrait) ?? font
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): bold, NSAttributedString.Key(kCTForegroundColorAttributeName as String): white]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textHeight = ascent + descent
        // Core Graphics counts from the bottom left; the placement counts from the top left.
        let left = at.x - lineWidth * at.alignX
        let top = at.y - textHeight * at.alignY
        context.saveGState()
        context.setAlpha(CGFloat(opacity))
        context.setShadow(offset: CGSize(width: 0, height: -at.fontSize / 16), blur: at.fontSize / 4, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
        context.textPosition = CGPoint(x: left, y: Double(height) - top - ascent)
        CTLineDraw(line, context)
        context.restoreGState()
        return context.makeImage() ?? image
    }
}
