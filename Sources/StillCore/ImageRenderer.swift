import AppKit
import UniformTypeIdentifiers
import ImageIO
import CoreImage

public enum RenderError: LocalizedError {
    case allocation, encoding, invalidCrop
    public var errorDescription: String? {
        switch self {
        case .allocation: return "The image is too large to render. Crop it or close other apps and try again."
        case .encoding: return "The image could not be encoded. Try exporting as PNG."
        case .invalidCrop: return "Select a crop inside the image."
        }
    }
}

public enum ImageRenderer {
    public static func render(_ source: CGImage, marks: [Mark] = [], frame: FrameStyle = .none, padding: Int = 64,
                              cornerRadius: Double = 12, shadow: Double = 24, aspectRatio: Double? = nil, customBackground: Data? = nil,
                              alignmentX: Double = 0.5, alignmentY: Double = 0.5, maxDimension: Int? = nil, cache: PreviewCache? = nil) throws -> CGImage {
        let framed = frame != .none || customBackground != nil
        let layout = canvasLayout(source: CGSize(width: source.width, height: source.height), framed: framed, padding: padding, aspect: aspectRatio, alignmentX: alignmentX, alignmentY: alignmentY)
        let width = Int(layout.size.width), height = Int(layout.size.height)
        let offsetX = Int(layout.origin.x), offsetY = height-source.height-Int(layout.origin.y)
        // Small previews draw the same picture through a scaled context; exports always stay at full size.
        let scale = min(1, Double(maxDimension ?? Int.max)/Double(max(1, max(width, height))))
        let outputWidth = scale < 1 ? max(1, Int(Double(width)*scale)) : width, outputHeight = scale < 1 ? max(1, Int(Double(height)*scale)) : height
        guard width > 0, height > 0, width <= 30000, height <= 30000,
              Int64(width)*Int64(height) <= 120_000_000,
              let ctx = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.allocation }
        if scale < 1 { ctx.scaleBy(x: CGFloat(outputWidth)/CGFloat(width), y: CGFloat(outputHeight)/CGFloat(height)) }
        ctx.interpolationQuality = .high
        if framed {
            let colors = frame.colors.map(\.cgColor) as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
            }
            if let customBackground, let image = cache?.background(customBackground) ?? decodedImage(customBackground) {
                let scale = max(CGFloat(width)/CGFloat(image.width), CGFloat(height)/CGFloat(image.height))
                let w = CGFloat(image.width)*scale, h = CGFloat(image.height)*scale
                ctx.draw(image, in: CGRect(x: (CGFloat(width)-w)/2, y: (CGFloat(height)-h)/2, width: w, height: h))
            }
            let r = CGRect(x: offsetX, y: offsetY, width: source.width, height: source.height)
            ctx.saveGState()
            // Shadows ignore the context's scale, so a scaled preview scales them by hand.
            ctx.setShadow(offset: CGSize(width: 0, height: -shadow/2*scale), blur: shadow*scale, color: NSColor.black.withAlphaComponent(shadow == 0 ? 0 : 0.25).cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)); ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)); ctx.clip()
        }
        ctx.translateBy(x: CGFloat(offsetX), y: CGFloat(offsetY))
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        draw(marks: marks, in: ctx, source: source, cache: cache)
        guard let result = ctx.makeImage() else { throw RenderError.allocation }
        return result
    }
    public static func canvasLayout(source: CGSize, framed: Bool, padding: Int, aspect: Double?, alignmentX: Double = 0.5, alignmentY: Double = 0.5) -> (size: CGSize, origin: CGPoint) {
        let inset = framed ? Double(max(0, min(padding, 512))) : 0
        var width = source.width+inset*2, height = source.height+inset*2
        if framed, let aspect, aspect.isFinite, aspect >= 0.1, aspect <= 10 {
            if width/height < aspect { width = ceil(height*aspect) } else { height = ceil(width/aspect) }
        }
        return (CGSize(width: width, height: height), CGPoint(x: inset+floor((width-source.width-inset*2)*max(0, min(1, alignmentX))), y: inset+floor((height-source.height-inset*2)*max(0, min(1, alignmentY)))))
    }
    public static func preview(_ source: CGImage, marks: [Mark], maxDimension: Int = 1800, cache: PreviewCache? = nil) throws -> CGImage {
        let scale = min(1, Double(maxDimension)/Double(max(source.width, source.height)))
        let width = max(1, Int(Double(source.width)*scale)), height = max(1, Int(Double(source.height)*scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.allocation }
        context.scaleBy(x: CGFloat(width)/CGFloat(source.width), y: CGFloat(height)/CGFloat(source.height))
        context.interpolationQuality = .high; context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height)); draw(marks: marks, in: context, source: source, cache: cache)
        guard let result = context.makeImage() else { throw RenderError.allocation }; return result
    }
    public static func contentBounds(_ source: CGImage) -> CGRect {
        let factor = min(1, 800/Double(max(source.width, source.height)))
        let w = max(1, Int(Double(source.width)*factor)), h = max(1, Int(Double(source.height)*factor))
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CGRect(x: 0, y: 0, width: source.width, height: source.height) }
        context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        let corners = [0, (w-1)*4, (h-1)*w*4, ((h-1)*w+w-1)*4]
        let bg = (0..<4).map { component in corners.reduce(0) { $0+Int(pixels[$1+component]) }/4 }
        let full = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard corners.allSatisfy({ offset in (0..<4).allSatisfy { abs(Int(pixels[offset+$0])-bg[$0]) < 24 } }) else { return full }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w { let offset = (y*w+x)*4; let differs = bg[3] < 24 ? pixels[offset+3] > 30 : (0..<4).contains { abs(Int(pixels[offset+$0])-bg[$0]) > 30 }; if differs { minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) } } }
        guard maxX >= minX, maxY >= minY else { return full }
        return CGRect(x: Double(minX)/factor, y: Double(minY)/factor, width: Double(maxX-minX+1)/factor, height: Double(maxY-minY+1)/factor).integral.intersection(full)
    }

    private static func decodedImage(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
    /// Blur and pixelate one region. A CIContext takes about 10 ms to build, too slow to make per mark, per frame.
    private static let filterContext = CIContext(options: [.useSoftwareRenderer: false])
    fileprivate static func filteredPatch(_ mark: Mark, cropRect: CGRect, source: CGImage) -> CGImage? {
        guard let patch = source.cropping(to: cropRect) else { return nil }
        let input = CIImage(cgImage: patch)
        let scale = max(12,mark.width*4), seed = mark.id.uuid
        let center = CIVector(x: Double(seed.0).truncatingRemainder(dividingBy: scale),y: Double(seed.1).truncatingRemainder(dividingBy: scale))
        let pixelated = input.clampedToExtent().applyingFilter("CIPixellate",parameters: [kCIInputScaleKey: scale,kCIInputCenterKey: center]).cropped(to: input.extent)
        let blurInput = mark.style == "smooth" ? input : pixelated
        let output = mark.tool == .blur ? blurInput.clampedToExtent().applyingFilter("CIGaussianBlur",parameters: [kCIInputRadiusKey: max(8,mark.width*3)]).cropped(to: input.extent) : pixelated
        return filterContext.createCGImage(output, from: input.extent)
    }
    /// How much a Loupe enlarges what's under it.
    public static let loupeZoom: CGFloat = 2
    private static func draw(marks: [Mark], in ctx: CGContext, source: CGImage, cache: PreviewCache? = nil) {
        let height = CGFloat(source.height)
        let p: (PixelPoint) -> CGPoint = { CGPoint(x: $0.x, y: height-$0.y) }
        let r: (CGRect) -> CGRect = { CGRect(x: $0.minX, y: height-$0.maxY, width: $0.width, height: $0.height) }
        let spotlights = marks.filter { $0.tool == .spotlight }
        if !spotlights.isEmpty {
            ctx.saveGState()
            ctx.addRect(CGRect(x: 0, y: 0, width: source.width, height: source.height))
            for spotlight in spotlights { ctx.addRect(r(spotlight.rect)) }
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor); ctx.drawPath(using: .eoFill)
            ctx.restoreGState()
        }
        for mark in marks {
            guard let first = mark.points.first, let last = mark.points.last else { continue }
            ctx.saveGState()
            let color = NSColor(hex: mark.color)
            ctx.setStrokeColor(color.cgColor); ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(mark.width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.setAlpha(min(1, max(0, mark.opacity ?? 1)))
            switch mark.tool {
            case .arrow, .line:
                let start = p(first), end = p(last)
                let curve = mark.style == "curved"
                let control = p(mark.curveControl)
                ctx.move(to: start)
                if curve { ctx.addQuadCurve(to: end, control: control) } else { ctx.addLine(to: end) }
                ctx.strokePath()
                if mark.tool == .line { break }
                let angle = curve ? atan2(end.y-control.y, end.x-control.x) : atan2(end.y-start.y, end.x-start.x)
                let length = max(16, mark.width*4)
                ctx.move(to: CGPoint(x: end.x-length*cos(angle-0.48), y: end.y-length*sin(angle-0.48)))
                ctx.addLine(to: end)
                ctx.addLine(to: CGPoint(x: end.x-length*cos(angle+0.48), y: end.y-length*sin(angle+0.48)))
                if mark.style == "filled" { ctx.closePath(); ctx.fillPath() } else { ctx.strokePath() }
                if mark.style == "double" {
                    ctx.move(to: CGPoint(x: start.x+length*cos(angle-0.48), y: start.y+length*sin(angle-0.48)))
                    ctx.addLine(to: start); ctx.addLine(to: CGPoint(x: start.x+length*cos(angle+0.48), y: start.y+length*sin(angle+0.48))); ctx.strokePath()
                }
            case .rectangle: ctx.stroke(r(mark.rect))
            case .filledRectangle: ctx.fill(r(mark.rect))
            case .ellipse: ctx.strokeEllipse(in: r(mark.rect))
            case .pen:
                ctx.move(to: p(first))
                if mark.points.count > 2 {
                    for index in 1..<mark.points.count-1 {
                        let current = p(mark.points[index]), next = p(mark.points[index+1])
                        ctx.addQuadCurve(to: CGPoint(x: (current.x+next.x)/2, y: (current.y+next.y)/2), control: current)
                    }
                }
                if let last = mark.points.last { ctx.addLine(to: p(last)) }; ctx.strokePath()
            case .highlight:
                ctx.setFillColor(NSColor(hex: "FFE366").withAlphaComponent(0.43).cgColor); ctx.fill(r(mark.rect))
            case .redact:
                // Solid, opaque redaction deliberately replaces the original pixels.
                ctx.setBlendMode(.copy); ctx.setFillColor(NSColor(hex: "202421").cgColor); ctx.fill(r(mark.rect).integral)
            case .blur, .pixelate:
                let cropRect = mark.rect.integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
                if !cropRect.isNull, cropRect.width > 1, cropRect.height > 1,
                   let processed = cache?.patch(mark, cropRect: cropRect, source: source) ?? filteredPatch(mark, cropRect: cropRect, source: source) { ctx.draw(processed, in: r(cropRect)) }
            case .image:
                if let data = mark.imageData, let img = cache?.picture(mark.id, data: data) ?? decodedImage(data) { ctx.draw(img, in: r(mark.rect)) }
            case .text, .number:
                let fontSize = max(18, mark.width*5)
                let font = NSFont.systemFont(ofSize: fontSize, weight: mark.style == "plain" ? .regular : .semibold)
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: mark.tool == .number || mark.style == "label" || mark.style == "bubble" ? NSColor.white : color]
                if mark.style == "outline" { attributes[.strokeColor] = color; attributes[.strokeWidth] = -3; attributes[.foregroundColor] = NSColor.white }
                if mark.style == "shadow" { let shadow = NSShadow(); shadow.shadowOffset = NSSize(width: 1, height: -2); shadow.shadowBlurRadius = 4; shadow.shadowColor = NSColor.black.withAlphaComponent(0.5); attributes[.shadow] = shadow }
                let text = NSAttributedString(string: mark.text, attributes: attributes)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                if mark.tool == .number {
                    let size = max(32, fontSize*1.7), point = p(first)
                    ctx.fillEllipse(in: CGRect(x: point.x-size/2, y: point.y-size/2, width: size, height: size))
                    let s = text.size(); text.draw(at: CGPoint(x: point.x-s.width/2, y: point.y-s.height/2))
                } else {
                    let s = text.size(), point = CGPoint(x: first.x, y: height-first.y-s.height)
                    if ["label", "border", "bubble"].contains(mark.style ?? "") {
                        let box = CGRect(x: point.x-8, y: point.y-5, width: s.width+16, height: s.height+10)
                        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
                        if mark.style == "border" { ctx.strokePath() } else { ctx.fillPath() }
                        if mark.style == "bubble" { ctx.move(to: CGPoint(x: box.minX+12, y: box.minY)); ctx.addLine(to: CGPoint(x: box.minX+12, y: box.minY-12)); ctx.addLine(to: CGPoint(x: box.minX+27, y: box.minY)); ctx.closePath(); ctx.fillPath() }
                    }
                    text.draw(at: point)
                }
                NSGraphicsContext.restoreGraphicsState()
            case .stamp:
                // The emoji fills the box's shorter side, centred in it.
                let box = r(mark.rect), size = min(box.width, box.height)
                guard size >= 4 else { break }
                let text = NSAttributedString(string: mark.text.isEmpty ? "✅" : mark.text, attributes: [.font: NSFont.systemFont(ofSize: size*0.8)])
                let s = text.size()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                text.draw(at: CGPoint(x: box.midX-s.width/2, y: box.midY-s.height/2))
                NSGraphicsContext.restoreGraphicsState()
            case .measure:
                // A line with a short bar across each end and its length in a pill at the middle.
                let start = p(first), end = p(last), angle = atan2(end.y-start.y, end.x-start.x), bar = max(8, mark.width*3)
                let n = CGPoint(x: -sin(angle)*bar, y: cos(angle)*bar)
                ctx.move(to: start); ctx.addLine(to: end)
                ctx.move(to: CGPoint(x: start.x-n.x, y: start.y-n.y)); ctx.addLine(to: CGPoint(x: start.x+n.x, y: start.y+n.y))
                ctx.move(to: CGPoint(x: end.x-n.x, y: end.y-n.y)); ctx.addLine(to: CGPoint(x: end.x+n.x, y: end.y+n.y)); ctx.strokePath()
                let size = max(13, mark.width*3.5)
                let text = NSAttributedString(string: mark.measureLabel, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white])
                let s = text.size(), w = s.width+size, h = size*1.7, mid = CGPoint(x: (start.x+end.x)/2, y: (start.y+end.y)/2)
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(x: mid.x-w/2, y: mid.y-h/2, width: w, height: h), cornerWidth: h/2, cornerHeight: h/2, transform: nil)); ctx.fillPath()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                text.draw(at: CGPoint(x: mid.x-s.width/2, y: mid.y-s.height/2))
                NSGraphicsContext.restoreGraphicsState()
            case .loupe:
                // A round lens over the box: what's at its centre, enlarged, with a rim in the mark's colour.
                let box = r(mark.rect), radius = min(box.width, box.height)/2
                guard radius >= 4 else { break }
                let center = CGPoint(x: box.midX, y: box.midY), circle = CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2)
                let seen = radius/loupeZoom, flippedY = height-center.y
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -max(2, radius/30)), blur: max(8, radius/5), color: NSColor.black.withAlphaComponent(0.35).cgColor)
                ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: circle)
                ctx.restoreGState()
                if let patch = source.cropping(to: CGRect(x: center.x-seen, y: flippedY-seen, width: seen*2, height: seen*2).integral) {
                    ctx.saveGState(); ctx.addEllipse(in: circle); ctx.clip()
                    ctx.interpolationQuality = .high; ctx.draw(patch, in: circle)
                    ctx.restoreGState()
                }
                ctx.setLineWidth(max(2, mark.width)); ctx.strokeEllipse(in: circle)
            case .crop, .select, .spotlight: break
            }
            ctx.restoreGState()
        }
    }

    public static func resize(_ source: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, width <= 30000, height <= 30000, Int64(width)*Int64(height) <= 120_000_000,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.allocation }
        ctx.interpolationQuality = .high; ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw RenderError.allocation }; return image
    }
    public static func orient(_ source: CGImage, orientation: Int32) throws -> CGImage {
        let image = CIImage(cgImage: source).oriented(forExifOrientation: orientation)
        guard let output = CIContext().createCGImage(image, from: image.extent) else { throw RenderError.allocation }; return output
    }

    public static func crop(_ source: CGImage, to rect: CGRect) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let clipped = rect.standardized.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2,
              let result = source.cropping(to: clipped) else { throw RenderError.invalidCrop }
        return result
    }

    public static func data(_ image: CGImage, jpeg: Bool = false) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else { throw RenderError.encoding }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.encoding }
        return data as Data
    }
    /// The bytes the library has always stored: a PNG that went through one encode and decode first, which turns a
    /// display's own colour profile into the standard one ImageIO resolves it to. The pixels never change, so asking a
    /// single pixel what that profile becomes gives the same file for one encode instead of two.
    public static func libraryData(_ image: CGImage) throws -> Data {
        if let pixel = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)), let space = decodedImage(try data(pixel))?.colorSpace,
           let retagged = image.copy(colorSpace: space) { return try data(retagged) }
        guard let decoded = decodedImage(try data(image)) else { throw RenderError.encoding }
        return try data(decoded)
    }
    public static func data(_ image: CGImage, format: String) throws -> Data {
        let type: UTType
        switch format.lowercased() { case "jpg", "jpeg": type = .jpeg; case "heic": type = .heic; case "tiff": type = .tiff; default: type = .png }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw RenderError.encoding }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encoding }
        return data as Data
    }

    /// A small copy of an image already in memory, without decoding anything from disk.
    public static func thumbnail(_ source: CGImage, maxPixelSize: Int) -> CGImage? {
        let scale = min(1, Double(maxPixelSize)/Double(max(1, max(source.width, source.height))))
        let width = max(1, Int(Double(source.width)*scale)), height = max(1, Int(Double(source.height)*scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
    /// A small copy read from a file. Decoding happens here, not at first draw, so it can run off the main thread.
    public static func thumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    public static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Apply the EXIF orientation (phone photos are often stored sideways) at full size.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        guard orientation != 1, let width = properties?[kCGImagePropertyPixelWidth] as? Int, let height = properties?[kCGImagePropertyPixelHeight] as? Int else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Decoded pieces an edit session redraws many times: finished blur and pixelate regions, dropped-in pictures and the
/// custom background. Only previews use it; exports always render from scratch. Use one per editor, on one thread.
public final class PreviewCache {
    private struct PatchKey: Hashable { let id: UUID; let tool: MarkTool; let rect: [CGFloat]; let width: Double; let style: String? }
    private var source: CGImage?
    private var patches: [PatchKey: CGImage] = [:]
    private var pictures: [UUID: (data: Data, image: CGImage)] = [:]
    private var backdrop: (data: Data, image: CGImage)?
    public init() {}
    fileprivate func patch(_ mark: Mark, cropRect: CGRect, source: CGImage) -> CGImage? {
        if self.source !== source { self.source = source; patches = [:] }
        let key = PatchKey(id: mark.id, tool: mark.tool, rect: [cropRect.minX, cropRect.minY, cropRect.width, cropRect.height], width: mark.width, style: mark.style)
        if let cached = patches[key] { return cached }
        guard let image = ImageRenderer.filteredPatch(mark, cropRect: cropRect, source: source) else { return nil }
        if patches.count >= 64 { patches = [:] }
        patches[key] = image
        return image
    }
    fileprivate func picture(_ id: UUID, data: Data) -> CGImage? {
        if let cached = pictures[id], cached.data == data { return cached.image }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        if pictures.count >= 64 { pictures = [:] }
        pictures[id] = (data, image)
        return image
    }
    fileprivate func background(_ data: Data) -> CGImage? {
        if let backdrop, backdrop.data == data { return backdrop.image }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        backdrop = (data, image)
        return image
    }
}
