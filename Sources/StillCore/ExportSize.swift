import Foundation
import CoreGraphics
import ImageIO

/// Save for Size: a picture made to a shape, a width and a file size, such as a square profile picture under 500 KB.
/// The Windows and Linux app's shared/fit-size.js follows the same rules.
public enum ExportSize {
    public static let maxSide = 8000

    public struct Plan: Equatable {
        public let crop: CGRect
        public let width: Int
        public let height: Int
    }
    /// The part of the picture kept (all of it, or the largest square in its middle) and the size it comes out at.
    /// A width of 0 keeps the kept part's own width; the height follows the shape.
    public static func plan(width sourceWidth: Int, height sourceHeight: Int, square: Bool, width: Int = 0) -> Plan {
        let side = min(sourceWidth, sourceHeight)
        let crop = square ? CGRect(x: (sourceWidth-side)/2, y: (sourceHeight-side)/2, width: side, height: side) : CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        let w = max(1, min(maxSide, width > 0 ? width : Int(crop.width)))
        let h = max(1, min(maxSide, Int((Double(w)*crop.height/crop.width).rounded())))
        return Plan(crop: crop, width: w, height: h)
    }

    public struct Result: Equatable {
        public let scale: Double
        public let quality: Double
        public let bytes: Int
        public let fits: Bool
    }
    /// Finds the best picture under `limit` bytes. `encode(scale, quality)` makes the picture at that fraction of the
    /// planned size and returns its byte count. JPEG: the highest quality from 0.92 down to 0.5 that fits; if even 0.5
    /// is too big, the picture gets smaller and the search runs again. PNG only gets smaller. No limit: full size at 0.92.
    public static func fit(limit: Int, jpeg: Bool, encode: (Double, Double) throws -> Int) rethrows -> Result {
        let top = 0.92, floor = 0.5
        guard limit > 0 else { return Result(scale: 1, quality: top, bytes: try encode(1, top), fits: true) }
        var scale = 1.0, best: Result?
        for _ in 0..<10 where scale >= 0.1 {
            if !jpeg {
                let bytes = try encode(scale, 1)
                if bytes <= limit { return Result(scale: scale, quality: 1, bytes: bytes, fits: true) }
                best = Result(scale: scale, quality: 1, bytes: bytes, fits: false)
                scale = shrink(scale, bytes, limit); continue
            }
            let atTop = try encode(scale, top)
            if atTop <= limit { return Result(scale: scale, quality: top, bytes: atTop, fits: true) }
            let atFloor = try encode(scale, floor)
            if atFloor <= limit {
                var lo = floor, hi = top, found = Result(scale: scale, quality: floor, bytes: atFloor, fits: true)
                for _ in 0..<6 {
                    let q = (lo+hi)/2, bytes = try encode(scale, q)
                    if bytes <= limit { lo = q; found = Result(scale: scale, quality: q, bytes: bytes, fits: true) } else { hi = q }
                }
                return found
            }
            best = Result(scale: scale, quality: floor, bytes: atFloor, fits: false)
            scale = shrink(scale, atFloor, limit)
        }
        return best ?? Result(scale: scale, quality: floor, bytes: 0, fits: false)
    }
    private static func shrink(_ scale: Double, _ bytes: Int, _ limit: Int) -> Double {
        scale * max(0.5, min(0.9, (Double(limit)/Double(bytes)).squareRoot()*0.95))
    }
    /// The planned picture at `scale` of its planned size. A JPEG has no transparency, so it goes on white first
    /// (rounded corners and shadows would otherwise turn black).
    public static func render(_ source: CGImage, plan: Plan, scale: Double, opaque: Bool) throws -> CGImage {
        let w = max(1, Int((Double(plan.width)*scale).rounded())), h = max(1, Int((Double(plan.height)*scale).rounded()))
        let kept = plan.crop.width == CGFloat(source.width) && plan.crop.height == CGFloat(source.height) ? source : try ImageRenderer.crop(source, to: plan.crop)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.allocation }
        if opaque { ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.interpolationQuality = .high; ctx.draw(kept, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { throw RenderError.allocation }
        return image
    }
    public static func encode(_ image: CGImage, jpeg: Bool, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil) else { throw RenderError.encoding }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encoding }
        return data as Data
    }
    /// The whole job: the bytes of the best picture under `limit` (0 for none), and how it came out.
    public static func make(_ source: CGImage, plan: Plan, limit: Int, jpeg: Bool) throws -> (data: Data, width: Int, height: Int, fits: Bool) {
        var last: (scale: Double, quality: Double, data: Data)?
        let result = try fit(limit: limit, jpeg: jpeg) { scale, quality in
            let data = try encode(render(source, plan: plan, scale: scale, opaque: jpeg), jpeg: jpeg, quality: quality)
            last = (scale, quality, data); return data.count
        }
        // The search's answer is usually the last one it made; otherwise make it again.
        let data = last.map { $0.scale == result.scale && $0.quality == result.quality } == true ? last!.data
            : try encode(render(source, plan: plan, scale: result.scale, opaque: jpeg), jpeg: jpeg, quality: result.quality)
        return (data, max(1, Int((Double(plan.width)*result.scale).rounded())), max(1, Int((Double(plan.height)*result.scale).rounded())), result.fits)
    }
    public static func label(_ bytes: Int) -> String {
        bytes >= 1024*1024 ? String(format: "%.1f MB", Double(bytes)/1024/1024) : "\(max(1, Int((Double(bytes)/1024).rounded()))) KB"
    }
}
