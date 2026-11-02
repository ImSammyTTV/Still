import CoreGraphics
import ImageIO

/// Find Similar: each screenshot gets a 64-bit fingerprint from a 9 × 8 grey copy of it, one bit per neighbouring
/// pair (is the left one brighter than the right?). Pictures that look alike differ in few bits, whatever their size,
/// scaling or file format. Follows Desktop/src-tauri/src/similar.rs and shares its test cases.
public enum ImageFingerprint {
    /// How many of the 64 bits may differ for two pictures to count as similar.
    public static let similar = 12

    /// The fingerprint of 72 grey values, 9 across and 8 down (0 = black, 255 = white).
    public static func fromGrey(_ grey: [UInt8]) -> UInt64 {
        var bits: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { bits = (bits << 1) | (grey[y*9+x] > grey[y*9+x+1] ? 1 : 0) } }
        return bits
    }
    public static func fingerprint(_ image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: 9*8*4)
        guard let context = CGContext(data: &pixels, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 36, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Transparent parts count as white, as they look on most pages.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 9, height: 8))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        let grey = (0..<72).map { i -> UInt8 in
            let r = Double(pixels[i*4]), g = Double(pixels[i*4+1]), b = Double(pixels[i*4+2])
            return UInt8(min(255, max(0, (0.299*r + 0.587*g + 0.114*b).rounded())))
        }
        return fromGrey(grey)
    }
    /// The fingerprint of an image file, read at a small size so large screenshots stay quick.
    public static func fingerprint(of url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        return fingerprint(image)
    }
    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
    /// The candidates within `similar` of `target`, closest first (ties keep their order), at most `limit` of them.
    public static func rank<ID>(_ target: UInt64, _ candidates: [(ID, UInt64)], limit: Int) -> [(ID, Int)] {
        let found = candidates.enumerated().map { ($0.offset, $0.element.0, distance(target, $0.element.1)) }.filter { $0.2 <= similar }
        return Array(found.sorted { ($0.2, $0.0) < ($1.2, $1.0) }.prefix(limit).map { ($0.1, $0.2) })
    }
}
