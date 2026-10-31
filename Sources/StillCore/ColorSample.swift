import CoreGraphics
import Foundation

/// Colours picked from the screen while choosing an area: the colour of one pixel, and the recent colours list
/// that the editor's palette shows.
public enum ColorSample {
    /// The colour of one pixel as #RRGGBB in sRGB, with `x` and `y` in the image's own pixels from the top left.
    public static func hex(in image: CGImage, x: Int, y: Int) -> String? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? String(format: "#%02X%02X%02X", rgba[0], rgba[1], rgba[2]) : nil
    }

    /// `color` added to the front of `list`: newest first, no repeats, at most `max`.
    public static func remember(_ color: String, in list: [String], max: Int = 10) -> [String] {
        let value = color.uppercased()
        return Array(([value] + list.filter { $0.uppercased() != value }).prefix(max))
    }
}
