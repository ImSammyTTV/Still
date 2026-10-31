import CoreGraphics

/// Several captures joined into one picture, side by side or top to bottom. Each is scaled to the smallest height
/// (side by side) or width (top to bottom) among them, so none is enlarged and blurred, and they line up exactly.
/// Windows and Linux follow the same rules (combine.rs) and share the test cases.
public enum CaptureCombine {
    /// The size of the whole, and where each picture goes (from the top left).
    public static func layout(_ sizes: [CGSize], vertical: Bool) -> (size: CGSize, frames: [CGRect]) {
        let sizes = sizes.map { CGSize(width: max(1, $0.width), height: max(1, $0.height)) }
        guard !sizes.isEmpty else { return (.zero, []) }
        let side = vertical ? sizes.map(\.width).min()! : sizes.map(\.height).min()!
        var frames: [CGRect] = [], along: CGFloat = 0
        for size in sizes {
            let frame = vertical
                ? CGRect(x: 0, y: along, width: side, height: max(1, (size.height * side / size.width).rounded()))
                : CGRect(x: along, y: 0, width: max(1, (size.width * side / size.height).rounded()), height: side)
            along += vertical ? frame.height : frame.width
            frames.append(frame)
        }
        return (vertical ? CGSize(width: side, height: along) : CGSize(width: along, height: side), frames)
    }

    /// The pictures drawn into their frames.
    public static func combine(_ images: [CGImage], vertical: Bool) -> CGImage? {
        let (size, frames) = layout(images.map { CGSize(width: $0.width, height: $0.height) }, vertical: vertical)
        guard size.width > 0, let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        for (image, frame) in zip(images, frames) {
            // Core Graphics counts from the bottom left.
            context.draw(image, in: CGRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height))
        }
        return context.makeImage()
    }
}
