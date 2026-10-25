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
        let w = 80, h = min(280, image.height)
        let a = sample(previous, width: w, height: h), b = sample(image, width: w, height: h)
        let difference = zip(a, b).reduce(0.0) { $0+abs(Double($1.0)-Double($1.1)) } / Double(a.count) / 255
        if difference < 0.003 { return false }
        let margin = max(3, h/18)
        var best = Double.greatestFiniteMagnitude, shift = 0
        func score(_ a: [UInt8], _ b: [UInt8], height: Int, displacement: Int, margin: Int, step: Int) -> Double {
            var rows: [Double] = []
            let begin = max(margin, -displacement+margin), end = min(height-margin, height-displacement-margin)
            guard end-begin > 20 else { return .greatestFiniteMagnitude }
            for y in stride(from: begin, to: end, by: step) {
                var sum = 0.0
                for x in stride(from: 5, to: w-5, by: 2) { sum += abs(Double(a[(y+displacement)*w+x])-Double(b[y*w+x])) }
                rows.append(sum/Double((w-10)/2)/255)
            }
            rows.sort()
            let keep = max(1, Int(Double(rows.count)*0.8))
            return rows.prefix(keep).reduce(0,+)/Double(keep)
        }
        let limit = max(3, h-margin*2-24)
        for d in -limit...limit where abs(d) > 1 {
            let value = score(a, b, height: h, displacement: d, margin: margin, step: 2)
            if value < best-0.00001 || (abs(value-best) < 0.00001 && abs(d) < abs(shift)) { best = value; shift = d }
        }
        guard best < 0.065, shift != 0 else { throw StitchError.noOverlap }
        var pixels = Int((Double(shift)*Double(image.height)/Double(h)).rounded())
        if image.height > h {
            let fullA = sample(previous, width: w, height: image.height), fullB = sample(image, width: w, height: image.height)
            let radius = max(2, Int(ceil(Double(image.height)/Double(h)))*2)
            var refined = Double.greatestFiniteMagnitude
            for candidate in pixels-radius...pixels+radius where candidate != 0 {
                let value = score(fullA, fullB, height: image.height, displacement: candidate, margin: max(3,image.height/18), step: max(1,image.height/350))
                if value < refined { refined = value; pixels = candidate }
            }
        }
        func fixedRows(fromBottom: Bool) -> Int {
            var count = 0
            for index in 0..<max(1,h/5) {
                let y = fromBottom ? h-1-index : index
                let delta = (5..<w-5).reduce(0.0) { $0+abs(Double(a[y*w+$1])-Double(b[y*w+$1])) }/Double(w-10)/255
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
    private func sample(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width*height)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .low; ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
}
