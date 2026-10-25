import AppKit
import ImageIO

public struct ProjectDocument: Codable {
    public var version = 1
    public var sourcePNG: Data
    public var marks: [Mark]
    public var frame: String
    public var padding: Double
    public var cornerRadius: Double
    public var shadow: Double
    public var aspectRatio: Double?
    public var customBackground: Data?
    public var alignmentX: Double?
    public var alignmentY: Double?
    public init(source: CGImage, marks: [Mark], frame: FrameStyle, padding: Double, cornerRadius: Double = 12, shadow: Double = 24, aspectRatio: Double? = nil, customBackground: Data? = nil, alignmentX: Double = 0.5, alignmentY: Double = 0.5) throws {
        sourcePNG = try ImageRenderer.data(source); self.marks = marks; self.frame = frame.rawValue
        self.padding = padding; self.cornerRadius = cornerRadius; self.shadow = shadow
        self.aspectRatio = aspectRatio; self.customBackground = customBackground
        self.alignmentX = alignmentX; self.alignmentY = alignmentY
    }
    public func sourceImage() -> CGImage? {
        guard let source = CGImageSourceCreateWithData(sourcePNG as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    public static func read(_ url: URL) throws -> ProjectDocument {
        let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
        guard document.version == 1, document.sourceImage() != nil else { throw RenderError.encoding }
        return document
    }
    public func write(_ url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
}
