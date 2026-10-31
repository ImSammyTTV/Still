import AppKit

public struct PixelPoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(_ point: CGPoint) { x = point.x; y = point.y }
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var cg: CGPoint { CGPoint(x: x, y: y) }
}

public enum MarkTool: String, CaseIterable, Codable, Identifiable {
    case select, arrow, rectangle, filledRectangle, ellipse, line, pen, highlight, text, number, redact, blur, pixelate, spotlight, loupe, crop, image
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .select: return "Select"
        case .filledRectangle: return "Filled Rectangle"
        case .line: return "Line"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .spotlight: return "Spotlight"
        case .loupe: return "Loupe"
        case .image: return "Add Image"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .number: return "Step"
        case .redact: return "Redact"
        case .crop: return "Crop"
        }
    }
    public var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .filledRectangle: return "square.fill"
        case .line: return "line.diagonal"
        case .blur: return "drop.fill"
        case .pixelate: return "square.grid.3x3.fill"
        case .spotlight: return "circle.lefthalf.filled"
        case .loupe: return "plus.magnifyingglass"
        case .image: return "photo.badge.plus"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .number: return "1.circle"
        case .redact: return "rectangle.fill"
        case .crop: return "crop"
        }
    }
    public var key: String {
        switch self {
        case .select: return "v"
        case .filledRectangle: return "f"
        case .line: return "l"
        case .blur: return "u"
        case .pixelate: return "x"
        case .spotlight: return "s"
        case .loupe: return "m"
        case .image: return "i"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .pen: return "p"
        case .highlight: return "h"
        case .text: return "t"
        case .number: return "n"
        case .redact: return "b"
        case .crop: return "c"
        }
    }
}

public struct Mark: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var tool: MarkTool
    public var points: [PixelPoint]
    public var color: String
    public var width: Double
    public var text: String
    public var style: String?
    public var imageData: Data?
    public var opacity: Double?
    public var control: PixelPoint?
    public var curveControl: PixelPoint {
        if let control { return control }
        guard let a = points.first, let b = points.last else { return PixelPoint(x: 0, y: 0) }
        return PixelPoint(x: (a.x+b.x)/2+(b.y-a.y)*0.3, y: (a.y+b.y)/2-(b.x-a.x)*0.3)
    }
    public init(tool: MarkTool, points: [PixelPoint], color: String = "FF6148", width: Double = 5, text: String = "") {
        self.tool = tool; self.points = points; self.color = color; self.width = width; self.text = text
    }
    public var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
    }
    public var bounds: CGRect {
        guard let p = points.first else { return .zero }
        if tool == .number { let radius = max(16, width*4.25); return CGRect(x: p.x-radius, y: p.y-radius, width: radius*2, height: radius*2) }
        if tool == .text {
            let fontSize = max(18, width*5)
            let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)])
            return CGRect(x: p.x, y: p.y, width: size.width+16, height: size.height+8)
        }
        let geometry = tool == .arrow && style == "curved" ? points+[curveControl] : points
        let xs = geometry.map(\.x), ys = geometry.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0)-(xs.min() ?? 0), height: (ys.max() ?? 0)-(ys.min() ?? 0)).insetBy(dx: -max(8, width), dy: -max(8, width))
    }
    public func moved(dx: Double, dy: Double) -> Mark {
        var value = self
        value.points = points.map { PixelPoint(x: $0.x+dx, y: $0.y+dy) }
        if let control { value.control = PixelPoint(x: control.x+dx, y: control.y+dy) }
        return value
    }
}

public enum FrameStyle: String, CaseIterable, Identifiable {
    case none, paper, sage, midnight, apricot, ocean, sky, mint, rose, coral, lavender, iris, dusk, sunrise, gold, graphite, snow, forest, teal, plum, crimson
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var colors: [NSColor] {
        switch self {
        case .none: return [.clear, .clear]
        case .paper: return [NSColor(hex: "F0ECE3"), NSColor(hex: "DDD5C5")]
        case .sage: return [NSColor(hex: "D9E6C7"), NSColor(hex: "8DAE91")]
        case .midnight: return [NSColor(hex: "343F53"), NSColor(hex: "111C2B")]
        case .apricot: return [NSColor(hex: "FFD9AF"), NSColor(hex: "EAA89D")]
        case .ocean: return [.init(hex: "0D5AAA"), .init(hex: "062454")]
        case .sky: return [.init(hex: "B9DEFF"), .init(hex: "5E9FE8")]
        case .mint: return [.init(hex: "C4F3DC"), .init(hex: "5AADA3")]
        case .rose: return [.init(hex: "FFE2E6"), .init(hex: "DF8BB0")]
        case .coral: return [.init(hex: "FFB09A"), .init(hex: "EF565C")]
        case .lavender: return [.init(hex: "D8D2FA"), .init(hex: "8C87DD")]
        case .iris: return [.init(hex: "B59CED"), .init(hex: "4D3596")]
        case .dusk: return [.init(hex: "202255"), .init(hex: "C75F84")]
        case .sunrise: return [.init(hex: "F5CF8A"), .init(hex: "EE8782")]
        case .gold: return [.init(hex: "F5DA97"), .init(hex: "BC833C")]
        case .graphite: return [.init(hex: "4B4C50"), .init(hex: "1D1E20")]
        case .snow: return [.white, .init(hex: "ECEFF2")]
        case .forest: return [.init(hex: "3D8061"), .init(hex: "12362D")]
        case .teal: return [.init(hex: "83D9D3"), .init(hex: "1F7C91")]
        case .plum: return [.init(hex: "A66AA5"), .init(hex: "3F1B57")]
        case .crimson: return [.init(hex: "E58D95"), .init(hex: "9E2045")]
        }
    }
}

public struct CaptureItem: Codable, Identifiable, Equatable {
    public let id: UUID
    public var filename: String
    public var title: String
    public let date: Date
    public let isVideo: Bool
    public var width: Int
    public var height: Int
    public var projectFilename: String?
    public var tags: [String]?
    public var recognizedText: String?
    public var cloudURL: String?
    public var metadataFilename: String?
    public var sourceVideoFilename: String?
    public init(filename: String, title: String, isVideo: Bool, width: Int = 0, height: Int = 0) {
        id = UUID(); self.filename = filename; self.title = title; date = Date()
        self.isVideo = isVideo; self.width = width; self.height = height
    }
}

public extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 255)/255,
                  green: CGFloat((value >> 8) & 255)/255,
                  blue: CGFloat(value & 255)/255, alpha: 1)
    }
}
