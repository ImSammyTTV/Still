import AppKit

public enum StitchAxis: String, CaseIterable, Identifiable { case vertical, horizontal; public var id: String { rawValue } }
public enum StitchError: LocalizedError {
    case noOverlap, differentSize
    public var errorDescription: String? {
        switch self {
        case .noOverlap: return "No matching overlap. Scroll back a little, then move more slowly."
        case .differentSize: return "The capture area changed size. Start a new scrolling capture."
        }
    }
}

public final class ScrollingStitcher: @unchecked Sendable {
    private var previous: CGImage
    private var combined: CGImage
    private var position = 0
    public let axis: StitchAxis
    public private(set) var frameCount = 1
    public init(_ first: CGImage, axis: StitchAxis = .vertical) throws {
        self.axis = axis
        let image = axis == .horizontal ? try ImageRenderer.orient(first, orientation: 6) : first
        previous = image; combined = image
    }
    public func result() throws -> CGImage { axis == .horizontal ? try ImageRenderer.orient(combined, orientation: 8) : combined }
    @discardableResult public func append(_ next: CGImage) throws -> Bool {
        let image = axis == .horizontal ? try ImageRenderer.orient(next, orientation: 6) : next
        guard image.width == previous.width, image.height == previous.height else { throw StitchError.differentSize }
        let w = Self.sampleWidth, edge = Self.sampleEdge, h = min(280, image.height)
        let a = sample(previous, width: w, height: h), b = sample(image, width: w, height: h)
        let difference = zip(a, b).reduce(0.0) { $0+abs(Double($1.0)-Double($1.1)) } / Double(a.count) / 255
        if difference < 0.003 { return false }
        let margin = max(3, h/18), limit = max(3, h-margin*2-24)
        let shifts = (-limit...limit).filter { abs($0) > 1 }
        let scores = shifts.map { Self.score(a, b, height: h, displacement: $0, margin: margin, step: 2) }
        let lowest = scores.map(\.trimmed).min() ?? .greatestFiniteMagnitude
        guard lowest < Self.match else { throw StitchError.noOverlap }
        // Repeated text can look like a match at the wrong shift, and the sample is too coarse to say which is
        // right. The closest contenders are judged at full height, and on a tie the one that overlaps most wins,
        // because it has the most rows agreeing with it.
        var contenders = shifts.indices.filter { i in
            let value = scores[i].trimmed
            return value < Self.match && value <= lowest+Self.close && (i == 0 || value <= scores[i-1].trimmed) && (i == shifts.count-1 || value <= scores[i+1].trimmed)
        }
        contenders.sort { (scores[$0].trimmed, scores[$0].overlap) < (scores[$1].trimmed, scores[$1].overlap) }
        contenders = Array(contenders.prefix(Self.contenders))
        let fullA = image.height > h ? sample(previous, width: w, height: image.height) : a
        let fullB = image.height > h ? sample(image, width: w, height: image.height) : b
        let radius = max(2, Int(ceil(Double(image.height)/Double(h))))*2
        var best = Score.worst, pixels = 0
        for index in contenders {
            let center = Int((Double(shifts[index])*Double(image.height)/Double(h)).rounded())
            for candidate in center-radius...center+radius where candidate != 0 {
                let value = Self.score(fullA, fullB, height: image.height, displacement: candidate, margin: max(3, image.height/18), step: max(1, image.height/350))
                if value.beats(best, smaller: abs(candidate) < abs(pixels)) { best = value; pixels = candidate }
            }
        }
        guard pixels != 0, best.upper < Self.exact else { throw StitchError.noOverlap }
        func fixedRows(fromBottom: Bool) -> Int {
            var count = 0
            for index in 0..<max(1,h/5) {
                let y = fromBottom ? h-1-index : index
                var difference = 0.0
                for x in edge..<w-edge { difference += abs(Double(a[y*w+x])-Double(b[y*w+x])) }
                let delta = difference/Double(w-2*edge)/255
                if delta > 0.007 { break }; count += 1
            }
            return min(image.height/4, Int(Double(count)*Double(image.height)/Double(h)))
        }
        let nextPosition = position+pixels
        let before = max(0,-nextPosition), after = max(0,nextPosition+image.height-combined.height)
        if before == 0 && after == 0 { previous = image; position = nextPosition; return false }
        let extensionSize = before+after, newHeight = combined.height+extensionSize
        guard newHeight <= 30000, Int64(combined.width)*Int64(newHeight) <= 120_000_000,
              let ctx = CGContext(data: nil, width: combined.width, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.allocation }
        if after > 0 {
            let footer = min(fixedRows(fromBottom: true), max(0, image.height-after-1))
            let stripHeight = after+footer, oldHeight = combined.height-footer
            guard let old = combined.cropping(to: CGRect(x: 0,y: 0,width: combined.width,height: oldHeight)), let strip = image.cropping(to: CGRect(x: 0,y: image.height-stripHeight,width: image.width,height: stripHeight)) else { throw RenderError.allocation }
            ctx.draw(old, in: CGRect(x: 0,y: stripHeight,width: old.width,height: old.height)); ctx.draw(strip,in: CGRect(x: 0,y: 0,width: strip.width,height: strip.height))
            position = nextPosition
        } else {
            let header = min(fixedRows(fromBottom: false), max(0,image.height-before-1))
            let stripHeight = before+header
            guard let old = combined.cropping(to: CGRect(x: 0,y: header,width: combined.width,height: combined.height-header)), let strip = image.cropping(to: CGRect(x: 0,y: 0,width: image.width,height: stripHeight)) else { throw RenderError.allocation }
            ctx.draw(old,in: CGRect(x: 0,y: 0,width: old.width,height: old.height)); ctx.draw(strip,in: CGRect(x: 0,y: old.height,width: strip.width,height: strip.height))
            position = 0
        }
        guard let result = ctx.makeImage() else { throw RenderError.allocation }
        previous = image; combined = result; frameCount += 1; return true
    }
    /// Columns sampled across the frame. Text needs this many: coarser samples blur lines into look-alikes.
    private static let sampleWidth = 320
    /// Columns left out on each side, because scrollbars move on their own.
    private static let sampleEdge = sampleWidth/16
    /// The worst average difference, from 0 to 1, that still counts as the same content.
    private static let match = 0.065
    /// The same at full height for the row 70% of the way from best to worst, where a true shift compares the very
    /// same pixels. Strict, because a refused frame can be recovered by scrolling back, and a bad join can't.
    private static let exact = 0.012
    /// How far behind the best a shift can be and still be looked at closely, and how many are.
    private static let close = 0.04
    private static let contenders = 24

    private struct Score {
        var trimmed: Double, overlap: Double, upper: Double
        static let worst = Score(trimmed: .greatestFiniteMagnitude, overlap: .greatestFiniteMagnitude, upper: .greatestFiniteMagnitude)
        /// A tie goes to `smaller`, the shift that moves the frame less.
        func beats(_ other: Score, smaller: Bool) -> Bool {
            if abs(trimmed-other.trimmed) >= 0.00001 { return trimmed < other.trimmed }
            if abs(overlap-other.overlap) >= 0.00000001 { return overlap < other.overlap }
            return smaller
        }
    }
    /// How badly row y+displacement of `a` differs from row y of `b`. The worst fifth of the rows is ignored, so sticky
    /// bars and small animations don't spoil a good match. The average over the whole overlap, margins included,
    /// settles ties on flat pages, where a shift slightly off can differ only in the ignored rows.
    private static func score(_ a: [UInt8], _ b: [UInt8], height: Int, displacement: Int, margin: Int, step: Int) -> Score {
        let w = sampleWidth, edge = sampleEdge
        let begin = max(margin, margin-displacement), end = min(height-margin, height-displacement-margin)
        guard end-begin > 20 else { return .worst }
        return a.withUnsafeBufferPointer { a in b.withUnsafeBufferPointer { b in
            func row(_ y: Int) -> Double {
                var sum = 0
                for x in stride(from: edge, to: w-edge, by: 2) { sum += abs(Int(a[(y+displacement)*w+x])-Int(b[y*w+x])) }
                return Double(sum)/Double((w-2*edge)/2)/255
            }
            var rows = stride(from: begin, to: end, by: step).map(row)
            rows.sort()
            let keep = max(1, Int(Double(rows.count)*0.8))
            let overlap = Array(stride(from: max(0, -displacement), to: min(height, height-displacement), by: step))
            return Score(trimmed: rows.prefix(keep).reduce(0, +)/Double(keep), overlap: overlap.map(row).reduce(0, +)/Double(overlap.count), upper: rows[rows.count*7/10])
        } }
    }
    private func sample(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width*height)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .low; ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
}
