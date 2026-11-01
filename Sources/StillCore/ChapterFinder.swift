import CoreGraphics
import Vision

/// The pieces of Find Chapters that read pictures: a tiny greyscale copy to compare frames by, and the name of a
/// chapter from the text on screen. The decisions are VideoChapters.scenes and VideoChapters.pickTitle.
public enum ChapterFinder {
    /// The picture at 32 × 18, as greyscale values from 0 to 255.
    public static func grey(_ image: CGImage) -> [Double] {
        let width = 32, height = 18
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return [] }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        return (0..<(width * height)).map { Double(bytes[$0]) }
    }

    /// The name for a chapter starting on this picture, or "" when no line of text reads like a title.
    public static func title(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let height = Double(image.height)
        let rows = (request.results ?? []).compactMap { observation -> (text: String, top: Double, height: Double)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return (text, (1 - box.maxY) * height, box.height * height)
        }
        return VideoChapters.pickTitle(rows)
    }
}
